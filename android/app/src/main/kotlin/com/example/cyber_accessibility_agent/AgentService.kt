package com.example.cyber_accessibility_agent

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import java.util.concurrent.Executors

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "agent_service_channel"
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
        executor.execute { initFlutter() }
    }

    private fun initFlutter() {
        if (flutterEngine != null) return

        try {
            val loader = FlutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundMain"
            )

            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            flutterEngine = engine
            Log.i(TAG, "Headless FlutterEngine started (backgroundMain)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FlutterEngine", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onDestroy() {
        flutterEngine?.destroy()
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Agent Service",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("System Service")
            .setContentText("Running")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
    }
}
