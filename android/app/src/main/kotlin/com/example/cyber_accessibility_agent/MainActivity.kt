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

    // Command dispatch channel (calls native CommandDispatcher.dispatch)
    private val COMMAND_CHANNEL = "cyber_accessibility_agent/commands"

    // Permissions channel for storage permission flows
    private val PERM_CHANNEL = "cyber_agent/permissions"
    private val PERM_REQUEST_CODE = 14523

    // Hold pending MethodChannel.Result for runtime permission callback
    private var pendingPermResult: MethodChannel.Result? = null

    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Commands channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMAND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dispatch" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("INVALID_ARGS", "expected a map", null)
                            return@setMethodCallHandler
                        }

                        executor.execute {
                            try {
                                val action = (args["action"] ?: "").toString()
                                val id = (args["id"] ?: "").toString()
                                val payload = (args["payload"] as? Map<*, *>) ?: emptyMap<Any, Any>()

                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = id,
                                    action = action,
                                    payload = payload
                                )

                                result.success(res)
                            } catch (e: Exception) {
                                Log.w(TAG, "dispatch exception: ${e.message}")
                                result.success(mapOf("success" to false, "error" to (e.message ?: "exception")))
                            }
                        }
                    }
                    "ping" -> {
                        result.success(mapOf("status" to "ok", "device" to android.os.Build.MODEL))
                    }
                    else -> result.notImplemented()
                }
            }

        // Permissions channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkStoragePermissions" -> {
                        result.success(currentMediaPermissionMap())
                    }
                    "hasAllFilesAccess" -> {
                        result.success(hasAllFilesAccess())
                    }
                    "requestManageAllFilesAccess" -> {
                        val opened = requestManageAllFilesAccess()
                        result.success(opened)
                    }
                    "requestReadMediaPermissions" -> {
                        requestReadMediaPermissions(result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------- Permissions helpers ----------

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // pre-Android 11 rely on READ/WRITE_EXTERNAL_STORAGE at runtime
            (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) ||
                (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
        }
    }

    private fun currentMediaPermissionMap(): Map<String, Any> {
        val sdk = Build.VERSION.SDK_INT
        val map = mutableMapOf<String, Any>()
        map["hasAllFilesAccess"] = hasAllFilesAccess()

        if (sdk >= Build.VERSION_CODES.TIRAMISU) {
            map["readMediaImages"] = (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED)
            map["readMediaVideo"] = (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED)
            map["readMediaAudio"] = (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_AUDIO) == PackageManager.PERMISSION_GRANTED)
        } else {
            map["readExternalStorage"] = (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
            map["writeExternalStorage"] = (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
        }

        return map
    }

    private fun requestManageAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return try {
                // Open app-specific All Files Access settings
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                intent.data = Uri.parse("package:$packageName")
                startActivity(intent)
                true
            } catch (e: Exception) {
                // fallback: open general all-files access page
                try {
                    val intent2 = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    startActivity(intent2)
                    true
                } catch (ex: Exception) {
                    Log.w(TAG, "requestManageAllFilesAccess failed: ${ex.message}")
                    false
                }
            }
        }
        return false
    }

    private fun requestReadMediaPermissions(result: MethodChannel.Result) {
        val sdk = Build.VERSION.SDK_INT
        val permsToRequest = mutableListOf<String>()
        if (sdk >= Build.VERSION_CODES.TIRAMISU) {
            permsToRequest.add(Manifest.permission.READ_MEDIA_IMAGES)
            permsToRequest.add(Manifest.permission.READ_MEDIA_VIDEO)
            permsToRequest.add(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            permsToRequest.add(Manifest.permission.READ_EXTERNAL_STORAGE)
            // optionally request WRITE_EXTERNAL_STORAGE if needed for writes
            // permsToRequest.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }

        val filtered = permsToRequest.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()

        if (filtered.isEmpty()) {
            result.success(currentMediaPermissionMap())
            return
        }

        pendingPermResult = result
        ActivityCompat.requestPermissions(this, filtered, PERM_REQUEST_CODE)
    }

    // ---------- Permission result handling ----------

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERM_REQUEST_CODE) {
            val map = mutableMapOf<String, Any>()
            for (i in permissions.indices) {
                val p = permissions[i]
                val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
                map[p] = granted
            }
            map["aggregate"] = currentMediaPermissionMap()
            pendingPermResult?.success(map)
            pendingPermResult = null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }
}