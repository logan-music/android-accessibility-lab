package com.example.cyber_accessibility_agent

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

/**
 * AppHider
 *
 * Handles hiding and unhiding the launcher icon safely.
 *
 * ✔ No app kill
 * ✔ No service interruption
 * ✔ Reversible
 * ✔ Android 8–14 compatible
 */
object AppHider {

    private const val TAG = "AppHider"

    /**
     * Hide the launcher icon.
     *
     * This disables MainActivity component in the launcher.
     */
    fun hide(context: Context): Boolean {
        return setLauncherState(
            context = context,
            enabled = false
        )
    }

    /**
     * Restore the launcher icon.
     */
    fun show(context: Context): Boolean {
        return setLauncherState(
            context = context,
            enabled = true
        )
    }

    /**
     * Check whether the launcher icon is currently visible.
     */
    fun isVisible(context: Context): Boolean {
        return try {
            val pm = context.packageManager
            val component = launcherComponent(context)

            val state = pm.getComponentEnabledSetting(component)

            // DEFAULT means enabled unless disabled explicitly
            state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        } catch (e: Exception) {
            Log.w(TAG, "isVisible error: ${e.message}")
            true
        }
    }

    /**
     * Internal launcher state switch.
     */
    private fun setLauncherState(
        context: Context,
        enabled: Boolean
    ): Boolean {
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

    /**
     * Returns the launcher activity component.
     *
     * IMPORTANT:
     * This MUST match the activity declared with LAUNCHER intent
     * in AndroidManifest.xml
     */
    private fun launcherComponent(context: Context): ComponentName {
        return ComponentName(
            context,
            "com.example.cyber_accessibility_agent.MainActivity"
        )
    }
}
