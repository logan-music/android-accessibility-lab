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

/**
 * AgentAccessibilityService.kt
 *
 * AccessibilityService that executes sanitized commands delivered via:
 *  - static dispatchCommand(...) (MainActivity fallback)
 *  - broadcast Intent with action ACTION_EXECUTE + extras (preferred)
 *
 * When an Intent carries a ResultReceiver, this service will attempt to send
 * a JSON string back in a Bundle under key "result" and a resultCode (0 success, 1 failure).
 *
 * WARNING: Use only with explicit consent on test/emulator devices.
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "AgentAccessibilitySvc"

        // Basic sanity limits
        private const val MAX_TEXT_LEN = 512
        private const val MAX_COORD = 10000.0
        private const val MAX_WAIT_MS = 120_000L

        // Allowed actions (these should match CommandParser/native expected action names)
        private val ALLOWED_ACTIONS = setOf(
            "click_text", "click_id", "set_text", "global_action",
            "scroll", "wait", "tap_coords", "open_app",
            "click", "click_id", "type", "open", "global", "scroll", "wait", "tap"
        )

        // Broadcast constants (must match MainActivity)
        const val ACTION_EXECUTE = "com.example.cyber_accessibility_agent.ACTION_EXECUTE"
        const val EXTRA_CMD_ID = "cmd_id"
        const val EXTRA_ACTION = "action"
        const val EXTRA_PAYLOAD = "payload" // JSON string
        const val EXTRA_RESULT_RECEIVER = "result_receiver"

        // Reference to running service (set on onServiceConnected)
        @Volatile
        private var INSTANCE: AgentAccessibilityService? = null

        /**
         * Called by native dispatcher (MainActivity) to dispatch a command synchronously/non-blocking.
         * Returns true if command was accepted/queued (not necessarily executed yet).
         */
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

    // Worker thread to serialize command execution
    private val workerThread = HandlerThread("agent-worker")
    private lateinit var workerHandler: Handler
    private val isRunning = AtomicBoolean(false)

    // Broadcast receiver to accept commands from MainActivity (preferred flow)
    private val execReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            if (intent.action != ACTION_EXECUTE) return

            val id = intent.getStringExtra(EXTRA_CMD_ID) ?: "unknown"
            val action = intent.getStringExtra(EXTRA_ACTION) ?: ""
            val payloadJson = intent.getStringExtra(EXTRA_PAYLOAD) ?: "{}"
            val rr = intent.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)

            // Try to parse payload JSON into Map
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

            // Enqueue command and provide ResultReceiver to get callback
            val accepted = enqueueCommand(id, action, payloadMap, rr)
            if (!accepted) {
                // if not accepted, reply immediate failure via ResultReceiver if present
                if (rr != null) {
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
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        INSTANCE = this

        workerThread.start()
        workerHandler = Handler(workerThread.looper)
        isRunning.set(true)

        // Configure service info (events / feedback)
        val info = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 50
            flags = AccessibilityServiceInfo.DEFAULT
        }
        this.serviceInfo = info

        // Register broadcast receiver for ACTION_EXECUTE
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
        // Intentionally minimal: not used for direct command handling here
    }

    override fun onInterrupt() {
        Log.w(TAG, "Service interrupted")
    }

    // -------------------------
    // Command queue / execution
    // -------------------------
    /**
     * Enqueue command for execution on the worker thread.
     * If a ResultReceiver is provided, the service will attempt to send back
     * a JSON-string result in a Bundle under key "result" and a resultCode (0 success, 1 failure).
     */
    private fun enqueueCommand(id: String, action: String, payload: Map<*, *>, rr: ResultReceiver?): Boolean {
        val normalizedAction = action.trim().lowercase()
        if (!ALLOWED_ACTIONS.contains(normalizedAction)) {
            Log.w(TAG, "Rejected unknown action: $action")
            return false
        }

        // shallow sanitize payload keys to String and keep values
        val safePayload = payload.filterKeys { it != null }.mapKeys { it.key.toString() }

        // Post to worker thread for execution
        workerHandler.post {
            var success = false
            val resultMap = mutableMapOf<String, Any?>("action" to normalizedAction)
            try {
                success = executeCommandInternal(id, normalizedAction, safePayload)
                resultMap["success"] = success
                resultMap["note"] = if (success) "executed" else "failed_to_execute"
            } catch (e: Exception) {
                Log.e(TAG, "Error executing command $id:$action -> ${e.message}", e)
                resultMap["success"] = false
                resultMap["error"] = e.message
            }

            // If ResultReceiver supplied, send result back
            if (rr != null) {
                try {
                    val jo = JSONObject()
                    for ((k, v) in resultMap) {
                        jo.put(k, v)
                    }
                    val b = Bundle()
                    b.putString("result", jo.toString())
                    rr.send(if (resultMap["success"] == true) 0 else 1, b)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send ResultReceiver reply: ${e.message}")
                }
            }
        }

        return true
    }

    /**
     * Execute the action synchronously on the worker thread.
     * Returns true on success, false on failure.
     */
    private fun executeCommandInternal(id: String, action: String, payload: Map<String, Any?>): Boolean {
        Log.i(TAG, "Executing command id=$id action=$action payload=$payload")

        try {
            when (action) {
                "click_text", "click" -> {
                    val text = (payload["text"] ?: payload["value"] ?: payload["query"] ?: "").toString()
                    if (text.isBlank() || text.length > MAX_TEXT_LEN) {
                        Log.w(TAG, "click_text rejected (blank/too-long)")
                        return false
                    }
                    return clickByText(text)
                }

                "click_id", "click_id" -> {
                    val rid = (payload["resource_id"] ?: payload["id"] ?: payload["view_id"] ?: "").toString()
                    if (rid.isBlank()) {
                        Log.w(TAG, "click_id rejected (empty id)")
                        return false
                    }
                    return clickByViewId(rid)
                }

                "set_text", "type" -> {
                    val text = (payload["text"] ?: payload["value"] ?: "").toString()
                    if (text.length > MAX_TEXT_LEN) {
                        Log.w(TAG, "set_text rejected (too long)")
                        return false
                    }
                    val target = (payload["target"] ?: payload["target_text"] ?: payload["resource_id"] ?: "").toString().takeIf { it.isNotBlank() }
                    return setTextToField(text, target)
                }

                "global_action", "global" -> {
                    val name = (payload["name"] ?: payload["action"] ?: "").toString().lowercase()
                    if (name.isBlank()) {
                        Log.w(TAG, "global_action missing name")
                        return false
                    }
                    return performGlobalActionByName(name)
                }

                "scroll" -> {
                    val dir = (payload["direction"] ?: payload["dir"] ?: "").toString().lowercase()
                    val amt = (payload["amount"] ?: payload["a"] ?: 1).toString().toIntOrNull() ?: 1
                    scroll(dir, amt)
                    return true
                }

                "wait" -> {
                    val ms = (payload["ms"] ?: payload["milliseconds"] ?: payload["duration"] ?: 0).toString().toLongOrNull() ?: 0L
                    val safe = ms.coerceIn(1L, MAX_WAIT_MS)
                    try {
                        Thread.sleep(safe)
                    } catch (_: InterruptedException) { }
                    return true
                }

                "tap_coords", "tap" -> {
                    val x = (payload["x"] ?: payload["cx"] ?: "").toString().toDoubleOrNull()
                    val y = (payload["y"] ?: payload["cy"] ?: "").toString().toDoubleOrNull()
                    if (x == null || y == null) {
                        Log.w(TAG, "tap_coords invalid coords")
                        return false
                    }
                    if (abs(x) > MAX_COORD || abs(y) > MAX_COORD) {
                        Log.w(TAG, "tap_coords out of bounds")
                        return false
                    }
                    performTap(x.toFloat(), y.toFloat())
                    return true
                }

                "open_app", "open", "select", "start", "launch" -> {
                    val pkg = (payload["package"] ?: payload["pkg"] ?: payload["app"] ?: "").toString()
                    if (pkg.isBlank()) {
                        Log.w(TAG, "open_app invalid package")
                        return false
                    }
                    launchApp(pkg)
                    return true
                }

                else -> {
                    Log.w(TAG, "Unknown action $action")
                    return false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "executeCommandInternal exception: ${e.message}", e)
            return false
        } finally {
            Log.i(TAG, "Command $id processed action=$action")
        }
    }

    // -------------------------
    // Action implementations
    // -------------------------

    private fun clickByText(text: String): Boolean {
        val root = rootInActiveWindow ?: run {
            Log.w(TAG, "clickByText: root window null")
            return false
        }

        var success = false
        try {
            val nodes = root.findAccessibilityNodeInfosByText(text)
            if (!nodes.isNullOrEmpty()) {
                for (node in nodes) {
                    if (tryPerformClick(node)) {
                        Log.i(TAG, "clickByText: clicked node for text='$text'")
                        success = true
                        break
                    }
                    try { node.recycle() } catch (_: Exception) {}
                }
            }
            if (!success) {
                // fallback: search by content description or partial match
                val descNodes = findNodeByContentDescription(root, text)
                if (!descNodes.isNullOrEmpty()) {
                    for (n in descNodes) {
                        if (tryPerformClick(n)) {
                            Log.i(TAG, "clickByText: clicked by content-desc for text='$text'")
                            success = true
                            break
                        }
                        try { n.recycle() } catch (_: Exception) {}
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "clickByText exception: ${e.message}")
        } finally {
            try { root.recycle() } catch (_: Exception) {}
        }
        return success
    }

    private fun findNodeByContentDescription(root: AccessibilityNodeInfo, text: String): List<AccessibilityNodeInfo>? {
        val out = mutableListOf<AccessibilityNodeInfo>()
        try {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)
            while (queue.isNotEmpty()) {
                val n = queue.removeFirst()
                val cd = n.contentDescription
                if (cd != null && cd.toString().contains(text, ignoreCase = true)) {
                    out.add(n)
                    continue
                }
                for (i in 0 until n.childCount) {
                    val c = n.getChild(i)
                    if (c != null) queue.add(c)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "findNodeByContentDescription error: ${e.message}")
        }
        return if (out.isEmpty()) null else out
    }

    private fun clickByViewId(viewId: String): Boolean {
        val root = rootInActiveWindow ?: run {
            Log.w(TAG, "clickByViewId: root window null")
            return false
        }

        try {
            val nodes = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    root.findAccessibilityNodeInfosByViewId(viewId)
                } else {
                    emptyList<AccessibilityNodeInfo>()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "find by id failed, fallback to text search: ${t.message}")
                emptyList<AccessibilityNodeInfo>()
            }

            if (!nodes.isNullOrEmpty()) {
                for (node in nodes) {
                    if (tryPerformClick(node)) {
                        Log.i(TAG, "clickByViewId: clicked node for id='$viewId'")
                        return true
                    }
                    try { node.recycle() } catch (_: Exception) {}
                }
            }

            // fallback: search by last segment of id as text
            val last = viewId.substringAfterLast('/')
            if (last.isNotBlank()) {
                return clickByText(last)
            }
        } catch (e: Exception) {
            Log.e(TAG, "clickByViewId exception: ${e.message}", e)
        } finally {
            try { root.recycle() } catch (_: Exception) {}
        }

        Log.w(TAG, "clickByViewId: not found id='$viewId'")
        return false
    }

    private fun setTextToField(text: String, target: String? = null): Boolean {
        var node: AccessibilityNodeInfo? = null
        val root = rootInActiveWindow ?: run {
            Log.w(TAG, "setTextToField: root null")
            return false
        }

        try {
            if (!target.isNullOrBlank()) {
                // try view id first
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    try {
                        val byId = root.findAccessibilityNodeInfosByViewId(target)
                        if (!byId.isNullOrEmpty()) node = byId.first()
                    } catch (_: Throwable) {
                        // ignore
                    }
                }
                // if not found by id, search by text
                if (node == null) {
                    val byText = root.findAccessibilityNodeInfosByText(target)
                    if (!byText.isNullOrEmpty()) node = byText.first()
                }
            }

            if (node == null) {
                node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: node
            }

            if (node == null) {
                Log.w(TAG, "setTextToField: no target node")
                return false
            }

            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) {
                val args = Bundle()
                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                val performed = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                Log.i(TAG, "setTextToField: ACTION_SET_TEXT performed=$performed")
                performed
            } else {
                node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val performedClick = tryPerformClick(node)
                Log.i(TAG, "setTextToField: fallback focus/click performed=$performedClick")
                performedClick
            }
        } catch (e: Exception) {
            Log.e(TAG, "setTextToField exception: ${e.message}", e)
            return false
        } finally {
            try { node?.recycle() } catch (_: Exception) {}
            try { root.recycle() } catch (_: Exception) {}
        }
    }

    private fun tryPerformClick(node: AccessibilityNodeInfo?): Boolean {
        if (node == null) return false
        try {
            if (node.isClickable) {
                val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                if (ok) return true
            }

            var parent = node.parent
            while (parent != null) {
                if (parent.isClickable) {
                    val ok = parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    try { parent.recycle() } catch (_: Exception) {}
                    return ok
                }
                val next = parent.parent
                try { parent.recycle() } catch (_: Exception) {}
                parent = next
            }
        } catch (e: Exception) {
            Log.w(TAG, "tryPerformClick exception: ${e.message}")
        } finally {
            try { node.recycle() } catch (_: Exception) {}
        }
        return false
    }

    private fun performGlobalActionByName(name: String): Boolean {
        return try {
            when (name) {
                "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
                "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
                "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
                "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
                "quick_settings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
                    } else false
                }
                else -> {
                    Log.w(TAG, "Unknown global action: $name")
                    false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "performGlobalActionByName error: ${e.message}", e)
            false
        }
    }

    private fun scroll(direction: String, amount: Int) {
        val root = rootInActiveWindow ?: run {
            Log.w(TAG, "scroll: root null")
            return
        }

        val attempts = amount.coerceIn(1, 50)
        for (i in 0 until attempts) {
            try {
                when (direction) {
                    "up" -> root.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                    "down" -> root.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    "left" -> root.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                    "right" -> root.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    else -> Log.w(TAG, "scroll: invalid dir $direction")
                }
            } catch (e: Exception) {
                Log.w(TAG, "scroll attempt failed: ${e.message}")
            }
            try { Thread.sleep(150) } catch (_: InterruptedException) {}
        }
        try { root.recycle() } catch (_: Exception) {}
    }

    private fun performTap(x: Float, y: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val path = Path().apply { moveTo(x, y) }
                val gd = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
                    .build()
                dispatchGesture(gd, object : GestureDescription.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        Log.i(TAG, "tap completed at [$x,$y]")
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
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

    private fun launchApp(pkg: String) {
        try {
            val pm = packageManager
            val intent: Intent? = pm.getLaunchIntentForPackage(pkg)
            if (intent == null) {
                Log.w(TAG, "launchApp: no launch intent for $pkg")
                return
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            Log.i(TAG, "launchApp: started $pkg")
        } catch (e: Exception) {
            Log.e(TAG, "launchApp exception: ${e.message}", e)
        }
    }
}
