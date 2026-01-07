package com.example.cyber_accessibility_agent

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

object AppHider {

    private const val TAG = "AppHider"

    fun hide(context: Context): Boolean {
        return setLauncherState(context, false)
    }

    fun show(context: Context): Boolean {
        return setLauncherState(context, true)
    }

    fun isVisible(context: Context): Boolean {
        return try {
            val pm = context.packageManager
            val component = launcherComponent(context)
            val state = pm.getComponentEnabledSetting(component)
            state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        } catch (e: Exception) {
            Log.w(TAG, "isVisible error: ${e.message}")
            true
        }
    }

    private fun setLauncherState(context: Context, enabled: Boolean): Boolean {
        return try {
            val pm = context.packageManager
            val component = launcherComponent(context)

            val newState =
                if (enabled)
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED

            pm.setComponentEnabledSetting(
                component,
                newState,
                PackageManager.DONT_KILL_APP
            )

            Log.i(
                TAG,
                "Launcher icon ${if (enabled) "ENABLED" else "DISABLED"}"
            )
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to change launcher state: ${e.message}", e)
            false
        }
    }

    private fun launcherComponent(context: Context): ComponentName {
        return ComponentName(
            context,
            "com.example.cyber_accessibility_agent.MainActivity"
        )
    }
}
