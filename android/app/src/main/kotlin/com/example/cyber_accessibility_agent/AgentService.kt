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
        startForeground(NOTIF_ID, buildNotification("Agent starting"))

        scheduler = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
        scheduler?.scheduleAtFixedRate({
            Log.d(TAG, "keepalive tick")
        }, 30, 30, TimeUnit.SECONDS)

        // initialize headless FlutterEngine asynchronously off main thread
        bgExecutor.execute {
            try {
                initFlutterEngineAndStartDart()
            } catch (e: Exception) {
                Log.w(TAG, "Error init FlutterEngine: ${e.message}")
            }
        }
    }

    private fun initFlutterEngineAndStartDart() {
        if (flutterEngine != null) return

        // Use FlutterLoader -> getInstance() to initialize Flutter assets and find app bundle
        val flutterLoader = FlutterLoader.getInstance()
        flutterLoader.startInitialization(applicationContext)
        flutterLoader.ensureInitializationComplete(applicationContext, null)

        val engine = FlutterEngine(applicationContext)

        // register MethodChannel on this engine so Dart can call native dispatch
        MethodChannel(engine.dartExecutor.binaryMessenger, "cyber_accessibility_agent/commands")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dispatch" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("INVALID_ARGS", "expected a map", null)
                            return@setMethodCallHandler
                        }

                        // run native work on bgExecutor to avoid blocking dart isolate thread
                        bgExecutor.execute {
                            try {
                                val action = (args["action"] ?: "").toString()
                                val id = (args["id"] ?: "").toString()
                                val payload = (args["payload"] as? Map<*, *>) ?: emptyMap<Any, Any>()

                                val res = CommandDispatcher.dispatch(
                                    context = this,
                                    id = id,
                                    action = action,
                                    payload = payload
                                )

                                result.success(res)
                            } catch (e: Exception) {
                                Log.w(TAG, "dispatch exception: ${e.message}")
                                result.success(mapOf("success" to false, "error" to (e.message ?: "exception")))
                            }
                        }
                    }
                    "ping" -> {
                        result.success(mapOf("status" to "ok", "device" to android.os.Build.MODEL))
                    }
                    else -> result.notImplemented()
                }
            }

        // execute Dart entrypoint "backgroundMain" in app bundle
        val appBundlePath = flutterLoader.findAppBundlePath()
        val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, "backgroundMain")
        engine.dartExecutor.executeDartEntrypoint(entrypoint)

        flutterEngine = engine
        Log.i(TAG, "FlutterEngine created and backgroundMain started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when (action) {
            ACTION_START -> {
                Log.i(TAG, "AgentService ACTION_START")
            }
            ACTION_STOP -> {
                Log.i(TAG, "AgentService ACTION_STOP -> stopping")
                stopSelf()
            }
            else -> {
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
        } catch (e: Exception) {
            Log.w(TAG, "onDestroy cleanup error: ${e.message}")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(CHANNEL_ID, "Agent Service", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Media Agent background service"
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
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
