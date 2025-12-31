package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.*
import java.util.concurrent.TimeUnit

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
        private const val UNIQUE_ONE_OFF = "boot_sync_once"
        private const val UNIQUE_PERIODIC = "device_heartbeat_periodic"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        val action = intent.action ?: return

        val isBootEvent =
            action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED || // 🔥 Android 7+
            action == "android.intent.action.QUICKBOOT_POWERON"

        if (!isBootEvent) return

        Log.i(TAG, "Boot event received: $action")

        val appContext = context.applicationContext
        val wm = WorkManager.getInstance(appContext)

        val networkConstraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        /**
         * 1️⃣ ONE-TIME BOOT SYNC
         * - Ensures device row exists in Supabase
         * - Re-registers if data was wiped
         */
        val oneOff = OneTimeWorkRequestBuilder<BootSyncWorker>()
            .setConstraints(networkConstraints)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                30,
                TimeUnit.SECONDS
            )
            .build()

        wm.enqueueUniqueWork(
            UNIQUE_ONE_OFF,
            ExistingWorkPolicy.REPLACE,
            oneOff
        )

        /**
         * 2️⃣ PERIODIC HEARTBEAT
         * - Keeps device "online"
         * - Android min interval = 15 minutes
         */
        val periodic = PeriodicWorkRequestBuilder<BootSyncWorker>(
            15, TimeUnit.MINUTES
        )
            .setConstraints(networkConstraints)
            .build()

        wm.enqueueUniquePeriodicWork(
            UNIQUE_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            periodic
        )

        Log.i(TAG, "Boot sync + heartbeat scheduled successfully")
    }
}