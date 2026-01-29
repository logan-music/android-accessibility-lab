// BootReceiver.kt - Restart service after reboot
package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {

    private val TAG = "BootReceiver"

    override fun onReceive(context: Context, intent: Intent) {
        AppLogger.init(context)
        
        val action = intent.action
        AppLogger.i(TAG, "BootReceiver triggered: $action")

        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                
                // ✅ Check if agent was previously started
                val prefs = context.getSharedPreferences("agent_prefs", Context.MODE_PRIVATE)
                val agentWasStarted = prefs.getBoolean("agent_started", false)
                
                if (agentWasStarted) {
                    AppLogger.i(TAG, "Agent was previously started - restarting service")
                    startAgentService(context)
                } else {
                    AppLogger.d(TAG, "Agent was never started - skipping")
                }
            }
            
            else -> {
                AppLogger.d(TAG, "Unknown action: $action")
            }
        }
    }

    private fun startAgentService(context: Context) {
        try {
            val intent = Intent(context, AgentService::class.java).apply {
                action = AgentService.ACTION_START
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(context, intent)
                AppLogger.i(TAG, "✅ AgentService started via startForegroundService")
            } else {
                context.startService(intent)
                AppLogger.i(TAG, "✅ AgentService started via startService")
            }
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to start AgentService", e)
        }
    }
}
