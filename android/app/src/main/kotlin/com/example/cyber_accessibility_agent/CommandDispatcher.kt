package com.example.cyber_accessibility_agent

import android.util.Log

/**
 * CommandDispatcher
 *
 * - Normalizes/validates payload coming from Flutter MethodChannel (Map<*, *>)
 * - Lightweight whitelisting & size checks
 * - Converts Map<*, *> -> Map<String, Any?> (safe)
 * - Dispatches to AgentAccessibilityService (which queues/executes)
 *
 * Note: Keep this for lab/demo only.
 */
object CommandDispatcher {
    private const val TAG = "CommandDispatcher"

    // Safety knobs
    private const val MAX_PAYLOAD_KEYS = 50
    private const val MAX_STRING_VALUE_LEN = 1024
    private const val MAX_DEPTH = 4

    // Allowed action set (includes canonical + legacy aliases)
    private val ALLOWED_ACTIONS = setOf(
        // canonical names used by parser/native
        "click", "click_id", "type", "open", "global", "scroll", "wait", "tap", "raw",
        // legacy/aliases
        "click_text", "clickid", "click_by_id", "set_text", "open_app", "select", "start", "launch", "tap_coords"
    )

    /**
     * Entry point called by MainActivity's MethodChannel handler (or other native caller).
     * Returns true if accepted/queued successfully (not a guarantee of execution).
     */
    @JvmStatic
    fun dispatchCommand(id: String, action: String, payload: Map<*, *>?): Boolean {
        try {
            Log.i(TAG, "dispatchCommand received id=$id action=$action payload_keys=${payload?.size ?: 0}")

            val normAction = action.trim().lowercase()

            // Basic action whitelist
            if (!ALLOWED_ACTIONS.contains(normAction)) {
                Log.w(TAG, "dispatchCommand rejected unknown action: $action")
                return false
            }

            // Basic payload size check
            if (payload != null && payload.size > MAX_PAYLOAD_KEYS) {
                Log.w(TAG, "dispatchCommand rejected: payload too large (${payload.size} keys)")
                return false
            }

            // Normalize payload: Map<String, Any?>
            val safePayload = normalizePayload(payload, 0)

            // Additional lightweight checks (strings length)
            if (!inspectStringsSafe(safePayload)) {
                Log.w(TAG, "dispatchCommand rejected: payload contains overly long string")
                return false
            }

            // Optional: simple safety checks to avoid dangerous commands
            if (isPotentiallyDangerous(normAction, safePayload)) {
                Log.w(TAG, "dispatchCommand rejected: potential dangerous command action=$normAction payload=$safePayload")
                return false
            }

            // Dispatch to AccessibilityService (service handles queueing/execution)
            val accepted = AgentAccessibilityService.dispatchCommand(id, normAction, safePayload)
            Log.i(TAG, "dispatchCommand dispatch result for id=$id accepted=$accepted")
            return accepted
        } catch (t: Throwable) {
            Log.e(TAG, "dispatchCommand exception: ${t.message}", t)
            return false
        }
    }

    /**
     * Convert arbitrary Map<*, *> -> Map<String, Any?> safely.
     * Keys become strings via toString(); values are:
     *  - primitives (Number, Boolean, String) kept as-is (strings trimmed)
     *  - nested Maps converted recursively (limited depth)
     *  - Lists converted to List<Any?> preserving primitives/maps
     */
    private fun normalizePayload(src: Map<*, *>?, depth: Int = 0): Map<String, Any?> {
        if (src == null) return emptyMap()
        if (depth > MAX_DEPTH) {
            // avoid deep recursion / abuse
            return emptyMap()
        }

        val dst = mutableMapOf<String, Any?>()
        for ((k, v) in src) {
            val key = k?.toString() ?: continue
            dst[key] = when (v) {
                null -> null
                is Number, is Boolean -> v
                is String -> {
                    val s = v.trim()
                    if (s.length > MAX_STRING_VALUE_LEN) s.take(MAX_STRING_VALUE_LEN) else s
                }
                is Map<*, *> -> normalizePayload(v as Map<*, *>, depth + 1)
                is List<*> -> v.map { item ->
                    when (item) {
                        null -> null
                        is Number, is Boolean -> item
                        is String -> {
                            val s = item.trim()
                            if (s.length > MAX_STRING_VALUE_LEN) s.take(MAX_STRING_VALUE_LEN) else s
                        }
                        is Map<*, *> -> normalizePayload(item as Map<*, *>, depth + 1)
                        else -> item.toString()
                    }
                }
                else -> v.toString()
            }
        }
        return dst
    }

    /**
     * Ensure string values are not excessively long (defensive).
     */
    private fun inspectStringsSafe(map: Map<String, Any?>): Boolean {
        for ((_, v) in map) {
            when (v) {
                is String -> if (v.length > MAX_STRING_VALUE_LEN) return false
                is Map<*, *> -> if (!inspectStringsSafe(v as Map<String, Any?>)) return false
                is List<*> -> {
                    for (item in v) {
                        if (item is String && item.length > MAX_STRING_VALUE_LEN) return false
                        if (item is Map<*, *> && !inspectStringsSafe(item as Map<String, Any?>)) return false
                    }
                }
            }
        }
        return true
    }

    /**
     * Very small heuristic set of checks to avoid obviously dangerous payloads.
     * Expand as needed. For lab use only.
     */
    private fun isPotentiallyDangerous(action: String, payload: Map<String, Any?>): Boolean {
        // Disallow payloads that attempt to execute shell-like instructions or long scripts
        payload.forEach { (_, v) ->
            if (v is String) {
                if (v.contains("||") || v.contains(";") || v.contains("rm ") || v.contains("su ")) return true
            }
            if (v is List<*>) {
                // scan list items
                v.forEach { item ->
                    if (item is String && (item.contains("rm ") || item.contains("su "))) return true
                }
            }
        }

        // Disallow extremely high scroll counts or wait times encoded here (defensive)
        if (action == "scroll") {
            val amt = (payload["amount"] as? Number)?.toInt() ?: (payload["a"] as? Number)?.toInt() ?: 0
            if (amt > 1000) return true
        }
        if (action == "wait") {
            val ms = (payload["ms"] as? Number)?.toLong() ?: (payload["milliseconds"] as? Number)?.toLong() ?: 0L
            if (ms > 300_000L) return true
        }

        return false
    }
}
