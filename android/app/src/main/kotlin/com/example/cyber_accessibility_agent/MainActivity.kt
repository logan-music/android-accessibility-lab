package com.example.cyber_accessibility_agent

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * MainActivity for Cyber Accessibility Agent
 *
 * - Registers MethodChannel 'accessibility_bridge'
 * - Forwards executeCommand calls to AccessibilityService via broadcast Intent
 * - Waits for ResultReceiver callback and returns result to Flutter
 * - Adds a timeout to avoid hanging if service doesn't respond
 *
 * Note: AccessibilityService should register a BroadcastReceiver listening
 *       for AccessibilityBridgeService.ACTION_EXECUTE and return results
 *       via the provided ResultReceiver (see AccessibilityBridgeService pseudo-code).
 */
class MainActivity: FlutterActivity() {

    private val CHANNEL = "accessibility_bridge"
    private val RESPONSE_TIMEOUT_MS = 10_000L // 10 seconds

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "executeCommand" -> {
                    // validate args
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "Arguments missing or invalid", null)
                        return@setMethodCallHandler
                    }

                    val cmdId = args["id"]?.toString() ?: ""
                    val action = args["action"]?.toString() ?: ""
                    val payloadMap = args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()

                    // prepare JSON payload string
                    val payloadJson = try {
                        JSONObject(payloadMap as Map<*, *>).toString()
                    } catch (e: Exception) {
                        JSONObject().toString()
                    }

                    // Handler & timeout runnable
                    val mainHandler = Handler(Looper.getMainLooper())
                    val timeoutRunnable = Runnable {
                        // Timeout fired — return failure to Flutter
                        try {
                            result.success(mapOf("success" to false, "error" to "timeout"))
                        } catch (_: Exception) { /* ignore */ }
                    }
                    mainHandler.postDelayed(timeoutRunnable, RESPONSE_TIMEOUT_MS)

                    // ResultReceiver that will be passed to the AccessibilityService
                    val rr = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                        override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                            // Cancel timeout
                            mainHandler.removeCallbacks(timeoutRunnable)

                            val payloadStr = resultData?.getString("result")
                            if (payloadStr == null) {
                                // no payload string: return simple success boolean
                                try {
                                    result.success(mapOf("success" to (resultCode == 0)))
                                } catch (_: Exception) { /* ignore */ }
                                return
                            }

                            // Try to parse JSON payload returned by the service
                            try {
                                val jo = JSONObject(payloadStr)
                                // Convert JSONObject to Map<String, Any>
                                val map = mutableMapOf<String, Any?>()
                                val it = jo.keys()
                                while (it.hasNext()) {
                                    val k = it.next()
                                    map[k] = jo.opt(k)
                                }
                                // include resultCode for debugging
                                map["__result_code"] = resultCode
                                try {
                                    result.success(map)
                                } catch (_: Exception) { /* ignore */ }
                            } catch (e: Exception) {
                                // not JSON — return raw string
                                try {
                                    result.success(mapOf("success" to (resultCode == 0), "result" to payloadStr))
                                } catch (_: Exception) { /* ignore */ }
                            }
                        }
                    }

                    // Create broadcast intent for the AccessibilityService to pick up
                    val intent = Intent(AccessibilityBridgeService.ACTION_EXECUTE).apply {
                        putExtra(AccessibilityBridgeService.EXTRA_CMD_ID, cmdId)
                        putExtra(AccessibilityBridgeService.EXTRA_ACTION, action)
                        putExtra(AccessibilityBridgeService.EXTRA_PAYLOAD, payloadJson)
                        putExtra(AccessibilityBridgeService.EXTRA_RESULT_RECEIVER, rr)
                    }

                    // send broadcast (non-blocking) — service should invoke ResultReceiver when done
                    try {
                        sendBroadcast(intent)
                    } catch (e: Exception) {
                        // If broadcast fails, cancel timeout and return error
                        mainHandler.removeCallbacks(timeoutRunnable)
                        result.error("BROADCAST_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No UI here; consent UI handled in Flutter
    }
}
