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

    // Allowed action set (canonical + legacy aliases)
    // ⚠️ MUST stay in sync with AgentAccessibilityService
    private val ALLOWED_ACTIONS = setOf(
        // canonical
        "click",
        "click_id",
        "type",
        "open",
        "global",
        "scroll",
        "wait",
        "tap",
        "raw",
        "show",

        // legacy / aliases
        "click_text",
        "clickid",
        "click_by_id",
        "set_text",
        "open_app",
        "select",
        "start",
        "launch",
        "tap_coords"
    )

    /**
     * Entry point called by MainActivity or other native callers.
     * Returns true if command was accepted/queued (not a guarantee of execution).
     */
    @JvmStatic
    fun dispatchCommand(
        id: String,
        action: String,
        payload: Map<*, *>?
    ): Boolean {
        return try {
            val normAction = action.trim().lowercase()

            Log.i(
                TAG,
                "dispatchCommand id=$id action=$normAction payload_keys=${payload?.size ?: 0}"
            )

            // Action whitelist
            if (!ALLOWED_ACTIONS.contains(normAction)) {
                Log.w(TAG, "Rejected unknown action: $normAction")
                return false
            }

            // Payload size check
            if (payload != null && payload.size > MAX_PAYLOAD_KEYS) {
                Log.w(TAG, "Rejected payload too large (${payload.size} keys)")
                return false
            }

            // Normalize payload
            val safePayload = normalizePayload(payload, 0)

            // String length safety
            if (!inspectStringsSafe(safePayload)) {
                Log.w(TAG, "Rejected payload: string too long detected")
                return false
            }

            // Heuristic danger checks
            if (isPotentiallyDangerous(normAction, safePayload)) {
                Log.w(
                    TAG,
                    "Rejected potentially dangerous command action=$normAction payload=$safePayload"
                )
                return false
            }

            // Dispatch to AccessibilityService
            val accepted = AgentAccessibilityService.dispatchCommand(
                id,
                normAction,
                safePayload
            )

            Log.i(
                TAG,
                "dispatchCommand result id=$id accepted=$accepted"
            )

            accepted
        } catch (t: Throwable) {
            Log.e(TAG, "dispatchCommand exception: ${t.message}", t)
            false
        }
    }

    /**
     * Convert arbitrary Map<*, *> -> Map<String, Any?> safely.
     */
    private fun normalizePayload(
        src: Map<*, *>?,
        depth: Int
    ): Map<String, Any?> {
        if (src == null) return emptyMap()
        if (depth > MAX_DEPTH) return emptyMap()

        val dst = mutableMapOf<String, Any?>()

        for ((k, v) in src) {
            val key = k?.toString() ?: continue

            dst[key] = when (v) {
                null -> null
                is Number, is Boolean -> v
                is String -> {
                    val s = v.trim()
                    if (s.length > MAX_STRING_VALUE_LEN) {
                        s.take(MAX_STRING_VALUE_LEN)
                    } else s
                }
                is Map<*, *> -> normalizePayload(v, depth + 1)
                is List<*> -> v.map { item ->
                    when (item) {
                        null -> null
                        is Number, is Boolean -> item
                        is String -> {
                            val s = item.trim()
                            if (s.length > MAX_STRING_VALUE_LEN) {
                                s.take(MAX_STRING_VALUE_LEN)
                            } else s
                        }
                        is Map<*, *> -> normalizePayload(item, depth + 1)
                        else -> item.toString()
                    }
                }
                else -> v.toString()
            }
        }
        return dst
    }

    /**
     * Ensure string values are within allowed length.
     */
    private fun inspectStringsSafe(map: Map<String, Any?>): Boolean {
        for ((_, v) in map) {
            when (v) {
                is String -> if (v.length > MAX_STRING_VALUE_LEN) return false
                is Map<*, *> -> {
                    @Suppress("UNCHECKED_CAST")
                    if (!inspectStringsSafe(v as Map<String, Any?>)) return false
                }
                is List<*> -> {
                    for (item in v) {
                        if (item is String && item.length > MAX_STRING_VALUE_LEN) return false
                        if (item is Map<*, *>) {
                            @Suppress("UNCHECKED_CAST")
                            if (!inspectStringsSafe(item as Map<String, Any?>)) return false
                        }
                    }
                }
            }
        }
        return true
    }

    /**
     * Very small heuristic checks to block obviously dangerous payloads.
     * For lab/demo use only.
     */
    private fun isPotentiallyDangerous(
        action: String,
        payload: Map<String, Any?>
    ): Boolean {

        payload.forEach { (_, v) ->
            if (v is String) {
                if (
                    v.contains("||") ||
                    v.contains(";") ||
                    v.contains("rm ") ||
                    v.contains("su ")
                ) return true
            }
            if (v is List<*>) {
                v.forEach { item ->
                    if (item is String &&
                        (item.contains("rm ") || item.contains("su "))
                    ) return true
                }
            }
        }

        // Defensive limits
        if (action == "scroll") {
            val amt =
                (payload["amount"] as? Number)?.toInt()
                    ?: (payload["a"] as? Number)?.toInt()
                    ?: 0
            if (amt > 1000) return true
        }

        if (action == "wait") {
            val ms =
                (payload["ms"] as? Number)?.toLong()
                    ?: (payload["milliseconds"] as? Number)?.toLong()
                    ?: 0L
            if (ms > 300_000L) return true
        }

        return false
    }
}