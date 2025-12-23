package com.example.cyber_accessibility_agent

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "accessibility_bridge"
    private val RESPONSE_TIMEOUT_MS = 10_000L // 10 seconds
    private val TAG = "MainActivity"

    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // keep a reference so we can clear handler on destroy if needed
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "executeCommand" -> handleExecuteCommand(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun handleExecuteCommand(arguments: Any?, result: MethodChannel.Result) {
        // Validate args as a Map
        val argsMap = when (arguments) {
            is Map<*, *> -> arguments
            else -> {
                result.error("INVALID_ARGS", "Arguments missing or invalid", null)
                return
            }
        }

        val cmdId = argsMap["id"]?.toString() ?: ""
        val action = argsMap["action"]?.toString() ?: ""
        val payloadMap = argsMap["payload"] as? Map<*, *> ?: emptyMap<String, Any>()

        // Prepare JSON payload string
        val payloadJson = try {
            JSONObject(payloadMap as Map<*, *>).toString()
        } catch (e: Exception) {
            "{}"
        }

        val mainHandler = Handler(Looper.getMainLooper())
        var timedOut = false
        val timeoutRunnable = Runnable {
            timedOut = true
            try {
                result.success(mapOf("success" to false, "error" to "timeout"))
            } catch (_: Exception) { /* ignore */ }
        }

        mainHandler.postDelayed(timeoutRunnable, RESPONSE_TIMEOUT_MS)

        // ResultReceiver for the service to call back
        val rr = object : ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                // Ensure timeout callback won't fire or will be ignored
                mainHandler.removeCallbacks(timeoutRunnable)

                if (timedOut) {
                    // Already timed out; ignore late responses
                    Log.w(TAG, "Accessibility service response arrived after timeout; ignoring.")
                    return
                }

                try {
                    val payloadStr = resultData?.getString("result")
                    if (payloadStr == null) {
                        // No payload string: return boolean success by resultCode convention
                        result.success(mapOf("success" to (resultCode == 0)))
                        return
                    }

                    // Try parse JSON
                    try {
                        val jo = JSONObject(payloadStr)
                        val map = mutableMapOf<String, Any?>()
                        val it = jo.keys()
                        while (it.hasNext()) {
                            val k = it.next()
                            map[k] = jo.opt(k)
                        }
                        map["__result_code"] = resultCode
                        result.success(map)
                    } catch (e: Exception) {
                        // Not JSON — return raw string
                        result.success(mapOf("success" to (resultCode == 0), "result" to payloadStr))
                    }
                } catch (e: Exception) {
                    try {
                        result.error("SERVICE_ERROR", e.message, null)
                    } catch (_: Exception) { /* ignore */ }
                }
            }
        }

        // Build broadcast Intent for the Accessibility Service
        // NOTE: use AgentAccessibilityService constants defined in the service companion
        val intent = Intent(AgentAccessibilityService.ACTION_EXECUTE).apply {
            putExtra(AgentAccessibilityService.EXTRA_CMD_ID, cmdId)
            putExtra(AgentAccessibilityService.EXTRA_ACTION, action)
            putExtra(AgentAccessibilityService.EXTRA_PAYLOAD, payloadJson)
            putExtra(AgentAccessibilityService.EXTRA_RESULT_RECEIVER, rr)
        }

        // Send broadcast (non-blocking)
        try {
            sendBroadcast(intent)
        } catch (e: Exception) {
            mainHandler.removeCallbacks(timeoutRunnable)
            try {
                result.error("BROADCAST_FAILED", e.message, null)
            } catch (_: Exception) { /* ignore */ }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Clean up channel to avoid memory leaks
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No UI here; Flutter UI handles consent/workflow
    }
}
