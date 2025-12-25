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

    // Receiver: notified when Accessibility service connects (AgentAccessibilityService broadcasts this)
    private val svcConnectedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AgentAccessibilityService.ACTION_SERVICE_CONNECTED) return

            val model = intent.getStringExtra("model") ?: ""
            val manufacturer = intent.getStringExtra("manufacturer") ?: ""

            // ensure call on main thread
            Handler(Looper.getMainLooper()).post {
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "executeCommand" -> handleExecuteCommand(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            registerReceiver(svcConnectedReceiver, IntentFilter(AgentAccessibilityService.ACTION_SERVICE_CONNECTED))
            Log.i(TAG, "Accessibility receiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "Receiver registration failed: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(svcConnectedReceiver)
        } catch (_: Exception) {}
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    // Handle method channel call (wrap into broadcast + optional ResultReceiver)
    private fun handleExecuteCommand(call: MethodCall, result: MethodChannel.Result) {
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

        val mainHandler = Handler(Looper.getMainLooper())
        var finished = false

        val timeout = Runnable {
            if (!finished) {
                finished = true
                result.success(mapOf("success" to false, "error" to "timeout"))
            }
        }

        mainHandler.postDelayed(timeout, RESPONSE_TIMEOUT_MS)

        val rr = object : ResultReceiver(mainHandler) {
            override fun onReceiveResult(resultCode: Int, data: Bundle?) {
                if (finished) return
                finished = true
                mainHandler.removeCallbacks(timeout)

                val payloadStr = data?.getString("result")
                if (payloadStr == null) {
                    result.success(mapOf("success" to (resultCode == 0)))
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

        val intent = Intent(AgentAccessibilityService.ACTION_EXECUTE).apply {
            putExtra(AgentAccessibilityService.EXTRA_CMD_ID, cmdId)
            putExtra(AgentAccessibilityService.EXTRA_ACTION, action)
            putExtra(AgentAccessibilityService.EXTRA_PAYLOAD, payloadJson)
            putExtra(AgentAccessibilityService.EXTRA_RESULT_RECEIVER, rr)
        }

        try {
            sendBroadcast(intent)
        } catch (e: Exception) {
            mainHandler.removeCallbacks(timeout)
            result.error("BROADCAST_FAILED", e.message, null)
        }
    }
}