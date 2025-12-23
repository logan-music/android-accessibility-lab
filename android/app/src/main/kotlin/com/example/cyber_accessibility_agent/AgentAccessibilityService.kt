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
import android.os.ResultReceiver
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
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
            "click", "type", "open", "global", "tap"
        )

        const val ACTION_EXECUTE =
            "com.example.cyber_accessibility_agent.ACTION_EXECUTE"
        const val EXTRA_CMD_ID = "cmd_id"
        const val EXTRA_ACTION = "action"
        const val EXTRA_PAYLOAD = "payload"
        const val EXTRA_RESULT_RECEIVER = "result_receiver"

        @Volatile
        private var INSTANCE: AgentAccessibilityService? = null

        @JvmStatic
        fun dispatchCommand(
            id: String,
            action: String,
            payload: Map<*, *>
        ): Boolean {
            val svc = INSTANCE ?: return false
            return svc.enqueueCommand(id, action, payload, null)
        }
    }

    // Worker thread
    private val workerThread = HandlerThread("agent-worker")
    private lateinit var workerHandler: Handler
    private val isRunning = AtomicBoolean(false)

    // Broadcast receiver
    private val execReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_EXECUTE) return

            val id = intent.getStringExtra(EXTRA_CMD_ID) ?: "unknown"
            val action = intent.getStringExtra(EXTRA_ACTION) ?: ""
            val payloadJson = intent.getStringExtra(EXTRA_PAYLOAD) ?: "{}"
            val rr = intent.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)

            val payloadMap = try {
                val jo = JSONObject(payloadJson)
                jo.keys().asSequence().associateWith { jo.opt(it) }
            } catch (_: Exception) {
                mapOf("value" to payloadJson)
            }

            if (!enqueueCommand(id, action, payloadMap, rr)) {
                rr?.send(
                    1,
                    Bundle().apply {
                        putString("result", """{"success":false}""")
                    }
                )
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        INSTANCE = this

        workerThread.start()
        workerHandler = Handler(workerThread.looper)
        isRunning.set(true)

        serviceInfo = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 50
        }

        registerReceiver(execReceiver, IntentFilter(ACTION_EXECUTE))
        Log.i(TAG, "Service connected")
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning.set(false)
        unregisterReceiver(execReceiver)
        workerThread.quitSafely()
        INSTANCE = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    // ===============================
    // ✅ THIS WAS MISSING (FIX)
    // ===============================
    private fun enqueueCommand(
        id: String,
        action: String,
        payload: Map<*, *>,
        rr: ResultReceiver?
    ): Boolean {

        val act = action.lowercase()
        if (!ALLOWED_ACTIONS.contains(act)) return false

        val safePayload = payload.mapKeys { it.key.toString() }

        workerHandler.post {
            val success = try {
                executeCommandInternal(id, act, safePayload)
            } catch (e: Exception) {
                false
            }

            rr?.send(
                if (success) 0 else 1,
                Bundle().apply {
                    putString(
                        "result",
                        """{"success":$success}"""
                    )
                }
            )
        }
        return true
    }

    private fun executeCommandInternal(
        id: String,
        action: String,
        payload: Map<String, Any?>
    ): Boolean {

        return when (action) {
            "tap", "tap_coords" -> {
                val x = payload["x"].toString().toFloatOrNull() ?: return false
                val y = payload["y"].toString().toFloatOrNull() ?: return false
                performTap(x, y)
                true
            }
            else -> true
        }
    }

    // ===============================
    // Gesture FIX (Android N+)
    // ===============================
    private fun performTap(x: Float, y: Float) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return

        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()

        dispatchGesture(
            gesture,
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    Log.i(TAG, "Tap completed")
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    Log.w(TAG, "Tap cancelled")
                }
            },
            null
        )
    }
}
