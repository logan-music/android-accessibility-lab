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
        checkAndStartAgent()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMAND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dispatch" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("INVALID_ARGS", "expected map", null)
                            return@setMethodCallHandler
                        }

                        executor.execute {
                            try {
                                val id = args["id"]?.toString() ?: ""
                                val action = args["action"]?.toString() ?: ""
                                val payload =
                                    args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()

                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = id,
                                    action = action,
                                    payload = payload
                                )
                                result.success(res)
                            } catch (e: Exception) {
                                Log.w(TAG, "dispatch error: ${e.message}")
                                result.success(
                                    mapOf(
                                        "success" to false,
                                        "error" to (e.message ?: "dispatch_error")
                                    )
                                )
                            }
                        }
                    }

                    "ping" -> {
                        result.success(
                            mapOf(
                                "status" to "ok",
                                "device" to Build.MODEL
                            )
                        )
                    }

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStoragePermissions" ->
                        result.success(currentMediaPermissionMap())

                    "hasAllFilesAccess" ->
                        result.success(hasAllFilesAccess())

                    "requestManageAllFilesAccess" ->
                        result.success(requestManageAllFilesAccess())

                    "requestReadMediaPermissions" ->
                        requestReadMediaPermissions(result)

                    else -> result.notImplemented()
                }
            }
    }

    private fun checkAndStartAgent() {
        val hasAllFiles = hasAllFilesAccess()
        val perms = currentMediaPermissionMap()

        val needsPermissions =
            !hasAllFiles ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    (
                        perms["readMediaImages"] != true ||
                        perms["readMediaVideo"] != true ||
                        perms["readMediaAudio"] != true
                    ))

        if (needsPermissions) {
            requestManageAllFilesAccess()
        } else {
            startAgentService()
        }
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
            Log.w(TAG, "Failed to start AgentService: ${e.message}")
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun currentMediaPermissionMap(): Map<String, Any> {
        val sdk = Build.VERSION.SDK_INT
        val map = mutableMapOf<String, Any>()

        map["hasAllFilesAccess"] = hasAllFilesAccess()

        if (sdk >= Build.VERSION_CODES.TIRAMISU) {
            map["readMediaImages"] =
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_MEDIA_IMAGES
                ) == PackageManager.PERMISSION_GRANTED

            map["readMediaVideo"] =
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_MEDIA_VIDEO
                ) == PackageManager.PERMISSION_GRANTED

            map["readMediaAudio"] =
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_MEDIA_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
        } else {
            map["readExternalStorage"] =
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED
        }

        return map
    }

    private fun requestManageAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return try {
                val intent =
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:$packageName")
                    }
                startActivity(intent)
                true
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    private fun requestReadMediaPermissions(result: MethodChannel.Result) {
        val perms = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.READ_MEDIA_IMAGES)
            perms.add(Manifest.permission.READ_MEDIA_VIDEO)
            perms.add(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            perms.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

        val need = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()

        if (need.isEmpty()) {
            result.success(currentMediaPermissionMap())
            startAgentService()
            return
        }

        pendingPermResult = result
        ActivityCompat.requestPermissions(this, need, PERM_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == PERM_REQUEST_CODE) {
            val map = mutableMapOf<String, Any>()

            permissions.forEachIndexed { index, perm ->
                map[perm] = grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            }

            map["aggregate"] = currentMediaPermissionMap()
            pendingPermResult?.success(map)
            pendingPermResult = null

            if (currentMediaPermissionMap().values.all { it == true }) {
                startAgentService()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }
}
