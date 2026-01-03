package com.example.cyber_accessibility_agent

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterMain
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "agent_service_channel"
        const val NOTIF_ID = 1001
        const val ACTION_START = "agent_start"
        const val ACTION_STOP = "agent_stop"
    }

    private val TAG = "AgentService"

    private var scheduler: ScheduledExecutorService? = null
    private var flutterEngine: FlutterEngine? = null
    private val bgExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()

        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification("Media Agent running"))

        scheduler = Executors.newSingleThreadScheduledExecutor()
        scheduler?.scheduleAtFixedRate({
            Log.d(TAG, "heartbeat tick")
        }, 30, 30, TimeUnit.SECONDS)

        bgExecutor.execute {
            try {
                initFlutterEngine()
            } catch (e: Exception) {
                Log.e(TAG, "FlutterEngine init error: ${e.message}", e)
            }
        }
    }

    private fun initFlutterEngine() {
        if (flutterEngine != null) return

        // 🔥 Flutter compatible initialization (OLD + NEW)
        FlutterMain.startInitialization(applicationContext)
        FlutterMain.ensureInitializationComplete(applicationContext, null)

        val engine = FlutterEngine(applicationContext)

        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "cyber_accessibility_agent/commands"
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "dispatch" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "Expected Map", null)
                        return@setMethodCallHandler
                    }

                    bgExecutor.execute {
                        try {
                            val id = args["id"]?.toString() ?: ""
                            val action = args["action"]?.toString() ?: ""
                            val payload =
                                args["payload"] as? Map<*, *> ?: emptyMap<Any, Any>()

                            val response = CommandDispatcher.dispatch(
                                context = this@AgentService,
                                id = id,
                                action = action,
                                payload = payload
                            )

                            result.success(response)
                        } catch (e: Exception) {
                            Log.e(TAG, "Dispatch error: ${e.message}", e)
                            result.success(
                                mapOf(
                                    "success" to false,
                                    "error" to (e.message ?: "dispatch_error")
                                )
                            )
                        }
                    }
                }

                "ping" -> {
                    result.success(
                        mapOf(
                            "status" to "ok",
                            "model" to android.os.Build.MODEL
                        )
                    )
                }

                else -> result.notImplemented()
            }
        }

        val bundlePath = FlutterMain.findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(bundlePath, "backgroundMain")
        )

        flutterEngine = engine
        Log.i(TAG, "Headless FlutterEngine started (backgroundMain)")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> Log.i(TAG, "AgentService START")
            ACTION_STOP -> {
                Log.i(TAG, "AgentService STOP")
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            scheduler?.shutdownNow()
            bgExecutor.shutdownNow()
            flutterEngine?.destroy()
            flutterEngine = null
        } catch (e: Exception) {
            Log.w(TAG, "Cleanup error: ${e.message}")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Media Agent",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Media Agent background service"
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE
            else 0
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Media Agent")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }
}
