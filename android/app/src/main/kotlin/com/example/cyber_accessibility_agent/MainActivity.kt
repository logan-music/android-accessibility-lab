package com.example.cyber_accessibility_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val TAG = "MainActivity"

    private val COMMAND_CHANNEL = "cyber_accessibility_agent/commands"
    private val PERM_CHANNEL = "cyber_agent/permissions"
    private val PERM_REQUEST_CODE = 14523

    private var pendingPermResult: MethodChannel.Result? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // ✅ auto-start agent if permissions already granted
        checkAndStartAgent()
    }

    override fun onResume() {
        super.onResume()
        // ✅ user may have granted MANAGE_EXTERNAL_STORAGE in settings
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

                        executor.execute {
                            try {
                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = args["id"]?.toString() ?: "",
                                    action = args["action"]?.toString() ?: "",
                                    payload = args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()
                                )
                                result.success(res)
                            } catch (e: Exception) {
                                Log.e(TAG, "dispatch error", e)
                                result.success(mapOf("success" to false, "error" to e.message))
                            }
                        }
                    }

                    "ping" -> result.success(
                        mapOf("status" to "ok", "device" to Build.MODEL)
                    )

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStoragePermissions" ->
                        result.success(currentPermissionMap())

                    "requestPermissions" ->
                        requestPermissions(result)

                    else -> result.notImplemented()
                }
            }
    }

    private fun checkAndStartAgent() {
        val perms = currentPermissionMap()
        if (perms.values.all { it }) {
            startAgentService()
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
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        }

        val filtered = need.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (filtered.isEmpty()) {
            result.success(currentPermissionMap())
            startAgentService()
            return
        }

        pendingPermResult = result
        ActivityCompat.requestPermissions(this, filtered.toTypedArray(), PERM_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != PERM_REQUEST_CODE) return

        val map = currentPermissionMap()
        pendingPermResult?.success(map)
        pendingPermResult = null

        if (map.values.all { it }) {
            startAgentService()
        }
    }

    private fun currentPermissionMap(): Map<String, Boolean> {
        val map = mutableMapOf<String, Boolean>()

        map["allFiles"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                Environment.isExternalStorageManager()
            else
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            map["images"] =
                ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES) ==
                    PackageManager.PERMISSION_GRANTED
            map["video"] =
                ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_VIDEO) ==
                    PackageManager.PERMISSION_GRANTED
            map["audio"] =
                ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
        }

        return map
    }

    private fun startAgentService() {
        try {
            val intent = Intent(this, AgentService::class.java).apply {
                action = AgentService.ACTION_START
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, intent)
            } else {
                startService(intent)
            }

            Log.i(TAG, "AgentService started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }
}