package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.*
import java.util.concurrent.TimeUnit

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        // Only react to BOOT_COMPLETED (and optionally QUICKBOOT)
        val action = intent.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED || action == "android.intent.action.QUICKBOOT_POWERON") {
            val wm = WorkManager.getInstance(context.applicationContext)

            // One-time immediate job to sync/create device row (lightweight)
            val oneOff = OneTimeWorkRequestBuilder<BootSyncWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            wm.enqueueUniqueWork("boot_sync_once", ExistingWorkPolicy.REPLACE, oneOff)

            // Periodic heartbeat (WorkManager min interval = 15 minutes)
            val periodic = PeriodicWorkRequestBuilder<BootSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            wm.enqueueUniquePeriodicWork("device_heartbeat_periodic", ExistingPeriodicWorkPolicy.KEEP, periodic)
        }
    }
}