package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        if (
            action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            try {
                val svc = Intent(context, AgentService::class.java).apply {
                    this.action = AgentService.ACTION_START
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(svc)
                } else {
                    context.startService(svc)
                }

                Log.i("BootReceiver", "Service restart requested")
            } catch (e: Exception) {
                Log.w("BootReceiver", "Service start blocked", e)
            }
        }
    }
}