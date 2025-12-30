package com.example.cyber_accessibility_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val CHANNEL = "accessibility_bridge"
    private val TAG = "MainActivity"
    private val RESPONSE_TIMEOUT_MS = 10_000L

    private var methodChannel: MethodChannel? = null
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    // 🔔 Receiver: Accessibility service connected
    private val svcConnectedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AgentAccessibilityService.ACTION_SERVICE_CONNECTED) return

            val model = intent.getStringExtra("model") ?: ""
            val manufacturer = intent.getStringExtra("manufacturer") ?: ""

            notifyFlutterAccessibilityEnabled(model, manufacturer)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "executeCommand" -> handleExecuteCommand(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Register receiver for service connected
        try {
            registerReceiver(
                svcConnectedReceiver,
                IntentFilter(AgentAccessibilityService.ACTION_SERVICE_CONNECTED)
            )
            Log.i(TAG, "Accessibility receiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "Receiver registration failed: ${e.message}")
        }

        // 🔁 NEW: if service already running, notify Flutter immediately
        mainHandler.postDelayed({
            tryNotifyIfServiceAlreadyRunning()
        }, 500)
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(svcConnectedReceiver)
        } catch (_: Exception) {}

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    // -------------------------
    // Accessibility status
    // -------------------------

    private fun tryNotifyIfServiceAlreadyRunning() {
        if (AgentAccessibilityService.dispatchCommand(
                id = "__ping__",
                action = "wait",
                payload = mapOf("ms" to 1)
            )
        ) {
            Log.i(TAG, "Accessibility service already running – notifying Flutter")
            notifyFlutterAccessibilityEnabled(
                android.os.Build.MODEL,
                android.os.Build.MANUFACTURER
            )
        }
    }

    private fun notifyFlutterAccessibilityEnabled(
        model: String,
        manufacturer: String
    ) {
        mainHandler.post {
            try {
                methodChannel?.invokeMethod(
                    "accessibility_enabled",
                    mapOf(
                        "model" to model,
                        "manufacturer" to manufacturer
                    )
                )
            } catch (e: Exception) {
                Log.w(TAG, "invokeMethod failed: ${e.message}")
            }
        }
    }

    // -------------------------
    // Command execution
    // -------------------------

    private fun handleExecuteCommand(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("INVALID_ARGS", "Invalid arguments", null)
            return
        }

        val cmdId = args["id"]?.toString() ?: ""
        val action = args["action"]?.toString() ?: ""
        val payload = args["payload"] as? Map<*, *> ?: emptyMap<String, Any>()

        val payloadJson = try {
            JSONObject(payload).toString()
        } catch (_: Exception) {
            "{}"
        }

        var finished = false

        val timeoutRunnable = Runnable {
            if (!finished) {
                finished = true
                result.success(
                    mapOf(
                        "success" to false,
                        "error" to "timeout"
                    )
                )
            }
        }

        mainHandler.postDelayed(timeoutRunnable, RESPONSE_TIMEOUT_MS)

        val rr = object : ResultReceiver(mainHandler) {
            override fun onReceiveResult(resultCode: Int, data: Bundle?) {
                if (finished) return
                finished = true
                mainHandler.removeCallbacks(timeoutRunnable)

                val payloadStr = data?.getString("result")
                if (payloadStr == null) {
                    result.success(
                        mapOf("success" to (resultCode == 0))
                    )
                    return
                }

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
                } catch (_: Exception) {
                    result.success(
                        mapOf(
                            "success" to (resultCode == 0),
                            "result" to payloadStr
                        )
                    )
                }
            }
        }

        // 🔁 Try direct dispatch first (fast path)
        val acceptedDirect = AgentAccessibilityService.dispatchCommand(
            cmdId,
            action,
            payload
        )

        if (acceptedDirect) {
            Log.i(TAG, "Command $cmdId dispatched directly to service")
            // Result will come via ResultReceiver if service supports it
        }

        // 🔄 Always send broadcast (fallback / guaranteed path)
        val intent = Intent(AgentAccessibilityService.ACTION_EXECUTE).apply {
            setPackage(packageName)
            putExtra(AgentAccessibilityService.EXTRA_CMD_ID, cmdId)
            putExtra(AgentAccessibilityService.EXTRA_ACTION, action)
            putExtra(AgentAccessibilityService.EXTRA_PAYLOAD, payloadJson)
            putExtra(AgentAccessibilityService.EXTRA_RESULT_RECEIVER, rr)
        }

        try {
            sendBroadcast(intent)
        } catch (e: Exception) {
            mainHandler.removeCallbacks(timeoutRunnable)
            result.error("BROADCAST_FAILED", e.message, null)
        }
    }
}