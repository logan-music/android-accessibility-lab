package com.example.cyber_accessibility_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
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
 * AgentAccessibilityService.kt — stable, broadcast-based command runner.
 *
 * Features:
 * - Broadcast receiver for ACTION_EXECUTE (accepts ResultReceiver in extras).
 * - Announces ACTION_SERVICE_CONNECTED broadcast once service is ready.
 * - Starts a lightweight foreground notification (keeps service alive on newer Android).
 * - enqueueCommand/executeCommandInternal run on a dedicated worker thread.
 *
 * Security/usage:
 * - Only intended for trusted test devices under explicit consent.
 * - Keep payload size / allowed actions limited.
 */

class AgentAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "AgentAccessibilitySvc"

        // Broadcasts / extras
        const val ACTION_EXECUTE = "com.example.cyber_accessibility_agent.ACTION_EXECUTE"
        const val ACTION_SERVICE_CONNECTED = "com.example.cyber_accessibility_agent.ACTION_SERVICE_CONNECTED"

        const val EXTRA_CMD_ID = "cmd_id"
        const val EXTRA_ACTION = "action"
        const val EXTRA_PAYLOAD = "payload" // JSON string
        const val EXTRA_RESULT_RECEIVER = "result_receiver" // Parcelable ResultReceiver

        // Keep small global context reference (safe usage: applicationContext)
        @Volatile
        private var appCtx: Context? = null

        // Best-effort reference to running service instance
        @Volatile
        private var INSTANCE: AgentAccessibilityService? = null

        /**
         * Try to dispatch directly if service present, otherwise send a broadcast (best-effort).
         * Returns true if the command was queued locally (fast path). If false, broadcast was sent.
         */
        @JvmStatic
        fun dispatchCommand(id: String, action: String, payload: Map<*, *>): Boolean {
            val svc = INSTANCE
            if (svc != null) {
                return svc.enqueueCommand(id, action, payload, null)
            }

            // fallback: send broadcast to be handled by service when available
            val ctx = appCtx ?: return false
            val intent = Intent(ACTION_EXECUTE).apply {
                setPackage(ctx.packageName)
                putExtra(EXTRA_CMD_ID, id)
                putExtra(EXTRA_ACTION, action)
                putExtra(EXTRA_PAYLOAD, JSONObject(payload as Map<*, *>).toString())
            }
            try {
                ctx.sendBroadcast(intent)
                Log.i(TAG, "dispatchCommand: broadcasted fallback $id/$action")
                return false
            } catch (e: Exception) {
                Log.w(TAG, "dispatchCommand: broadcast failed: ${e.message}")
                return false
            }
        }

        /**
         * Helper for other app components: send a broadcast to the service (single-line usage).
         * If you need a result, include a ResultReceiver instance in `rr`.
         */
        @JvmStatic
        fun sendCommandBroadcast(context: Context, id: String, action: String, payloadJson: String = "{}", rr: ResultReceiver? = null) {
            val intent = Intent(ACTION_EXECUTE).apply {
                setPackage(context.packageName)
                putExtra(EXTRA_CMD_ID, id)
                putExtra(EXTRA_ACTION, action)
                putExtra(EXTRA_PAYLOAD, payloadJson)
                if (rr != null) putExtra(EXTRA_RESULT_RECEIVER, rr)
            }
            context.sendBroadcast(intent)
        }
    }

    // -------------------------
    // Configuration / limits
    // -------------------------
    private val MAX_TEXT_LEN = 512
    private val MAX_COORD = 10000.0
    private val MAX_WAIT_MS = 120_000L

    private val ALLOWED_ACTIONS = setOf(
        "click_text", "click_id", "set_text", "global_action",
        "scroll", "wait", "tap_coords", "open_app",
        "click", "type", "open", "global", "tap", "select", "start", "launch", "show"
    )

    // Worker thread to serialize command execution
    private val workerThread = HandlerThread("agent-worker")
    private lateinit var workerHandler: Handler
    private val isRunning = AtomicBoolean(false)

    // Broadcast receiver — handles ACTION_EXECUTE
    private val commandReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            if (intent.action != ACTION_EXECUTE) return

            val id = intent.getStringExtra(EXTRA_CMD_ID) ?: "unknown"
            val action = intent.getStringExtra(EXTRA_ACTION) ?: ""
            val payloadJson = intent.getStringExtra(EXTRA_PAYLOAD) ?: "{}"
            val rr = intent.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)

            // parse payload into Map<String, Any?>
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
                Log.w(TAG, "commandReceiver: payload JSON parse failed: ${e.message}")
                mapOf("value" to payloadJson)
            }

            // enqueue for execution on worker
            val accepted = enqueueCommand(id, action, payloadMap, rr)
            if (!accepted && rr != null) {
                try {
                    val info = JSONObject()
                    info.put("success", false)
                    info.put("error", "rejected")
                    rr.send(1, Bundle().apply { putString("result", info.toString()) })
                } catch (e: Exception) {
                    Log.w(TAG, "commandReceiver: failed to send rejection rr: ${e.message}")
                }
            }
        }
    }

    // -------------------------
    // Lifecycle
    // -------------------------
    override fun onCreate() {
        super.onCreate()
        // store application context for broadcast fallback usage
        appCtx = applicationContext
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        INSTANCE = this

        // Start worker thread
        workerThread.start()
        workerHandler = Handler(workerThread.looper)
        isRunning.set(true)

        // Configure accessibility service behaviour
        val info = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 50
            flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        this.serviceInfo = info

        // register broadcast receiver (only once; safe to re-register after restart)
        try {
            val filter = IntentFilter(ACTION_EXECUTE)
            registerReceiver(commandReceiver, filter)
            Log.i(TAG, "commandReceiver registered for $ACTION_EXECUTE")
        } catch (e: Exception) {
            Log.w(TAG, "onServiceConnected: registerReceiver failed: ${e.message}")
        }

        // start foreground to improve stability on modern Android
        startForegroundNotification()

        // broadcast service connected (UI / other components might listen)
        try {
            val b = Intent(ACTION_SERVICE_CONNECTED).apply {
                putExtra("model", Build.MODEL)
                putExtra("manufacturer", Build.MANUFACTURER)
            }
            sendBroadcast(b)
            Log.i(TAG, "Broadcasted ACTION_SERVICE_CONNECTED")
        } catch (e: Exception) {
            Log.w(TAG, "Failed sending ACTION_SERVICE_CONNECTED: ${e.message}")
        }

        Log.i(TAG, "Service connected and worker started")
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning.set(false)
        try {
            unregisterReceiver(commandReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "onDestroy: unregisterReceiver failed: ${e.message}")
        }
        try {
            workerThread.quitSafely()
        } catch (_: Exception) {}
        INSTANCE = null
        Log.i(TAG, "Service destroyed")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // not used for command execution; keep if you want event-based triggers later
    }

    override fun onInterrupt() {
        Log.w(TAG, "Service interrupted")
    }

    // -------------------------
    // Foreground / keep-alive
    // -------------------------
    private fun startForegroundNotification() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val chId = "cyber_agent_channel_v1"
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val channel = NotificationChannel(chId, "Accessibility Agent", NotificationManager.IMPORTANCE_MIN)
                channel.setSound(null, null)
                nm.createNotificationChannel(channel)

                val n = Notification.Builder(this, chId)
                    .setContentTitle("Accessibility Agent")
                    .setContentText("Running")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setOngoing(true)
                    .build()
                startForeground(101, n)
            } else {
                // API < O: startForeground still allowed, using minimal fallback
                val n = Notification.Builder(this)
                    .setContentTitle("Accessibility Agent")
                    .setContentText("Running")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .build()
                startForeground(101, n)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForegroundNotification failed: ${e.message}")
        }
    }

    // -------------------------
    // Queueing / Execution
    // -------------------------
    /**
     * Enqueue command for execution on worker thread.
     * If a ResultReceiver is provided, service will attempt to send back a JSON-string
     * result in a Bundle under key "result" with resultCode 0 (success) or 1 (failure).
     */
    fun enqueueCommand(id: String, action: String, payload: Map<*, *>, rr: ResultReceiver?): Boolean {
        val normalizedAction = action.trim().lowercase()
        if (!ALLOWED_ACTIONS.contains(normalizedAction)) {
            Log.w(TAG, "Rejected unknown action: $action")
            return false
        }

        val safePayload = payload.filterKeys { it != null }.mapKeys { it.key.toString() }

        // Post to worker thread
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

            if (rr != null) {
                try {
                    val jo = JSONObject()
                    for ((k, v) in resultMap) jo.put(k, v)
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
                "click_text", "click", "show" -> {
                    val text = (payload["text"] ?: payload["value"] ?: payload["query"] ?: payload["what"] ?: "").toString()
                    if (text.isBlank() || text.length > MAX_TEXT_LEN) {
                        Log.w(TAG, "click_text/show rejected (blank/too-long)")
                        return false
                    }
                    return clickByText(text)
                }

                "click_id", "click_by_id" -> {
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
                    try { Thread.sleep(safe) } catch (_: InterruptedException) {}
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
                emptyList()
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
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    try {
                        val byId = root.findAccessibilityNodeInfosByViewId(target)
                        if (!byId.isNullOrEmpty()) node = byId.first()
                    } catch (_: Throwable) {}
                }
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