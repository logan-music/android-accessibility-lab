package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    private val TAG = "BootReceiver"

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        val action = intent.action ?: return

        if (action == Intent.ACTION_BOOT_COMPLETED
            || action == "android.intent.action.QUICKBOOT_POWERON"
            || action == "com.htc.intent.action.QUICKBOOT_POWERON"
            || action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            try {
                val svcIntent = Intent(context, AgentService::class.java).apply {
                    action = AgentService.ACTION_START
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(svcIntent)
                } else {
                    context.startService(svcIntent)
                }

                Log.i(TAG, "Requested start of AgentService (action=$action)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to start AgentService on boot: ${e.message}")
            }
        }
    }
}