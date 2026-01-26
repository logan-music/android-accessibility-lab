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
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "agent_service_channel"
        const val NOTIF_ID = 1001
        const val ACTION_START = "agent_start"
        const val CHANNEL_NAME = "Agent Background Service"
    }

    private val TAG = "AgentService"
    private var flutterEngine: FlutterEngine? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(
            NOTIF_ID,
            buildNotification("Waiting for device registration…")
        )
        Log.i(TAG, "Foreground service created")
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

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundMain"
            )

            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            // 🔗 MethodChannel for status updates
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "agent/status"
            ).setMethodCallHandler { call, result ->
                if (call.method == "updateStatus") {
                    val status = call.argument<String>("text") ?: "Running"
                    updateNotification(status)
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }

            flutterEngine = engine
            Log.i(TAG, "Headless FlutterEngine started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FlutterEngine", e)
        }
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
        Log.i(TAG, "Notification updated → $text")
    }

    override fun onDestroy() {
        flutterEngine?.destroy()
        flutterEngine = null
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
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("System Service")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}