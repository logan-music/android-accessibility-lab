package com.example.cyber_accessibility_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ResultReceiver
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.lang.Exception
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

class AgentAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "AgentAccessibilitySvc"

        private const val MAX_TEXT_LEN = 512
        private const val MAX_COORD = 10000.0
        private const val MAX_WAIT_MS = 120_000L

        private val ALLOWED_ACTIONS = setOf(
            "click_text", "click_id", "set_text", "global_action",
            "scroll", "wait", "tap_coords", "open_app",
            "click", "click_id", "type", "open", "global", "scroll", "wait", "tap"
        )

        const val ACTION_EXECUTE = "com.example.cyber_accessibility_agent.ACTION_EXECUTE"
        const val EXTRA_CMD_ID = "cmd_id"
        const val EXTRA_ACTION = "action"
        const val EXTRA_PAYLOAD = "payload" // JSON string
        const val EXTRA_RESULT_RECEIVER = "result_receiver"

        @Volatile
        private var INSTANCE: AgentAccessibilityService? = null

        @JvmStatic
        fun dispatchCommand(id: String, action: String, payload: Map<*, *>): Boolean {
            val svc = INSTANCE
            if (svc == null) {
                Log.w(TAG, "dispatchCommand: service not connected")
                return false
            }
            return svc.enqueueCommand(id, action, payload, null)
        }
    }

    // ... other fields, onServiceConnected, queueing etc remain the same as your original file ...
    private val workerThread = HandlerThread("agent-worker")
    private lateinit var workerHandler: Handler
    private val isRunning = AtomicBoolean(false)

    private val execReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            if (intent.action != ACTION_EXECUTE) return

            val id = intent.getStringExtra(EXTRA_CMD_ID) ?: "unknown"
            val action = intent.getStringExtra(EXTRA_ACTION) ?: ""
            val payloadJson = intent.getStringExtra(EXTRA_PAYLOAD) ?: "{}"
            val rr = intent.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)

            val payloadMap: Map<String, Any?> = try {
                val jo = JSONObject(payloadJson)
                val map = mutableMapOf<String, Any?>()
                val keys = jo.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = jo.opt(k)
                }
                map
            } catch (e: Exception) {
                Log.w(TAG, "execReceiver: payload JSON parse failed, wrapping raw string: ${e.message}")
                mapOf("value" to payloadJson)
            }

            val accepted = enqueueCommand(id, action, payloadMap, rr)
            if (!accepted && rr != null) {
                try {
                    val info = JSONObject()
                    info.put("success", false)
                    info.put("error", "rejected")
                    rr.send(1, Bundle().apply { putString("result", info.toString()) })
                } catch (e: Exception) {
                    Log.w(TAG, "execReceiver: failed to send rejection rr: ${e.message}")
                }
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        INSTANCE = this

        workerThread.start()
        workerHandler = Handler(workerThread.looper)
        isRunning.set(true)

        val info = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 50
            flags = AccessibilityServiceInfo.DEFAULT
        }
        this.serviceInfo = info

        try {
            val filter = IntentFilter(ACTION_EXECUTE)
            registerReceiver(execReceiver, filter)
            Log.i(TAG, "execReceiver registered for $ACTION_EXECUTE")
        } catch (e: Exception) {
            Log.w(TAG, "onServiceConnected: registerReceiver failed: ${e.message}")
        }

        Log.i(TAG, "Service connected and worker started")
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning.set(false)
        try {
            unregisterReceiver(execReceiver)
        } catch (e: Exception) {
            // ignore
        }
        workerThread.quitSafely()
        INSTANCE = null
        Log.i(TAG, "Service destroyed")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // not used
    }

    override fun onInterrupt() {
        Log.w(TAG, "Service interrupted")
    }

    // ... enqueueCommand, executeCommandInternal and other helper methods remain unchanged ...
    // Below: updated performTap using AccessibilityService.GestureResultCallback

    private fun performTap(x: Float, y: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val path = Path().apply { moveTo(x, y) }
                val gd = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
                    .build()

                // Use AccessibilityService.GestureResultCallback (correct callback type)
                dispatchGesture(gd, object : AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        super.onCompleted(gestureDescription)
                        Log.i(TAG, "tap completed at [$x,$y]")
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        super.onCancelled(gestureDescription)
                        Log.w(TAG, "tap cancelled at [$x,$y]")
                    }
                }, null)
            } catch (e: Exception) {
                Log.e(TAG, "performTap exception: ${e.message}", e)
            }
        } else {
            Log.w(TAG, "performTap: gesture API not available (requires N+)")
        }
    }

    // ... remaining functions (launchApp, clickByText, etc) unchanged from your original file ...
}
