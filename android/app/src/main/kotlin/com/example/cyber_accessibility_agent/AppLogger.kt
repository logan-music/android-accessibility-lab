// AppLogger.kt
package com.example.cyber_accessibility_agent

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executors

/**
 * Production-safe in-app logger that writes to persistent file.
 * NEVER crashes the app - all errors silently ignored.
 */
object AppLogger {
    
    private const val LOG_FILE_NAME = "app_log.txt"
    private const val MAX_LOG_SIZE = 5 * 1024 * 1024 // 5MB max
    private const val TAG = "AppLogger"
    
    private val executor = Executors.newSingleThreadExecutor()
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    
    @Volatile
    private var logFile: File? = null
    @Volatile
    private var initialized = false
    
    /**
     * Initialize logger with application context.
     * Call this in MainActivity.onCreate()
     */
    fun init(context: Context) {
        if (initialized) return
        
        try {
            // Use app-specific external storage (survives uninstall if on SD card)
            val logDir = context.getExternalFilesDir(null) ?: context.filesDir
            logFile = File(logDir, LOG_FILE_NAME)
            
            // Create file if doesn't exist
            if (!logFile!!.exists()) {
                logFile!!.createNewFile()
            }
            
            initialized = true
            
            // Write initialization marker
            i("AppLogger", "=== Logger initialized: ${logFile!!.absolutePath} ===")
            i("AppLogger", "App started at: ${dateFormat.format(Date())}")
            
        } catch (e: Exception) {
            // Silent failure - don't crash app
            Log.e(TAG, "Failed to initialize logger", e)
        }
    }
    
    /**
     * Info level log
     */
    fun i(tag: String, message: String) {
        log("INFO", tag, message, null)
    }
    
    /**
     * Debug level log
     */
    fun d(tag: String, message: String) {
        log("DEBUG", tag, message, null)
    }
    
    /**
     * Warning level log
     */
    fun w(tag: String, message: String) {
        log("WARN", tag, message, null)
    }
    
    /**
     * Error level log
     */
    fun e(tag: String, message: String, throwable: Throwable? = null) {
        log("ERROR", tag, message, throwable)
    }
    
    /**
     * Critical error - always logged
     */
    fun critical(tag: String, message: String, throwable: Throwable? = null) {
        log("CRITICAL", tag, message, throwable)
    }
    
    /**
     * Internal logging logic
     */
    private fun log(level: String, tag: String, message: String, throwable: Throwable?) {
        // Also log to Android logcat for development
        when (level) {
            "DEBUG" -> Log.d(tag, message, throwable)
            "INFO" -> Log.i(tag, message, throwable)
            "WARN" -> Log.w(tag, message, throwable)
            "ERROR", "CRITICAL" -> Log.e(tag, message, throwable)
        }
        
        if (!initialized || logFile == null) return
        
        // Write to file asynchronously to avoid blocking
        executor.execute {
            try {
                writeToFile(level, tag, message, throwable)
            } catch (e: Exception) {
                // Silent failure - never crash the app
                Log.e(TAG, "Failed to write log", e)
            }
        }
    }
    
    /**
     * Write log entry to file
     */
    private fun writeToFile(level: String, tag: String, message: String, throwable: Throwable?) {
        try {
            val file = logFile ?: return
            
            // Check file size and rotate if needed
            if (file.length() > MAX_LOG_SIZE) {
                rotateLog(file)
            }
            
            // Build log entry
            val timestamp = dateFormat.format(Date())
            val logEntry = StringBuilder()
            logEntry.append("[$timestamp] [$level] [$tag] $message\n")
            
            // Add stack trace if present
            if (throwable != null) {
                logEntry.append("  Exception: ${throwable.javaClass.simpleName}: ${throwable.message}\n")
                throwable.stackTrace.take(10).forEach { element ->
                    logEntry.append("    at $element\n")
                }
                
                // Add cause if present
                throwable.cause?.let { cause ->
                    logEntry.append("  Caused by: ${cause.javaClass.simpleName}: ${cause.message}\n")
                    cause.stackTrace.take(5).forEach { element ->
                        logEntry.append("    at $element\n")
                    }
                }
            }
            
            // Append to file
            FileWriter(file, true).use { writer ->
                writer.append(logEntry.toString())
                writer.flush()
            }
            
        } catch (e: Exception) {
            // Silent failure
            Log.e(TAG, "Write to file failed", e)
        }
    }
    
    /**
     * Rotate log file when it gets too large
     */
    private fun rotateLog(file: File) {
        try {
            val backupFile = File(file.parent, "${LOG_FILE_NAME}.old")
            
            // Delete old backup
            if (backupFile.exists()) {
                backupFile.delete()
            }
            
            // Rename current to backup
            file.renameTo(backupFile)
            
            // Create new log file
            file.createNewFile()
            
            FileWriter(file, false).use { writer ->
                writer.append("=== Log rotated at ${dateFormat.format(Date())} ===\n")
                writer.flush()
            }
            
        } catch (e: Exception) {
            // If rotation fails, just clear the file
            try {
                FileWriter(file, false).use { writer ->
                    writer.append("=== Log cleared (rotation failed) at ${dateFormat.format(Date())} ===\n")
                    writer.flush()
                }
            } catch (e2: Exception) {
                // Give up silently
            }
        }
    }
    
    /**
     * Get log file path for reading
     */
    fun getLogFilePath(): String? {
        return logFile?.absolutePath
    }
    
    /**
     * Get log file content (last N lines)
     */
    fun getLogContent(lastLines: Int = 500): String {
        try {
            val file = logFile ?: return "Log file not initialized"
            
            if (!file.exists()) {
                return "Log file does not exist"
            }
            
            val lines = file.readLines()
            val startIndex = maxOf(0, lines.size - lastLines)
            
            return lines.subList(startIndex, lines.size).joinToString("\n")
            
        } catch (e: Exception) {
            return "Error reading log: ${e.message}"
        }
    }
    
    /**
     * Clear log file
     */
    fun clearLog() {
        executor.execute {
            try {
                logFile?.let { file ->
                    FileWriter(file, false).use { writer ->
                        writer.append("=== Log cleared at ${dateFormat.format(Date())} ===\n")
                        writer.flush()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to clear log", e)
            }
        }
    }
    
    /**
     * Log app lifecycle event
     */
    fun logLifecycle(event: String) {
        i("Lifecycle", ">>> $event <<<")
    }
    
    /**
     * Log permission event
     */
    fun logPermission(permission: String, granted: Boolean) {
        if (granted) {
            i("Permission", "✓ $permission GRANTED")
        } else {
            w("Permission", "✗ $permission DENIED")
        }
    }
    
    /**
     * Log command execution
     */
    fun logCommand(commandId: String, action: String, status: String) {
        i("Command", "[$commandId] $action -> $status")
    }
    
    /**
     * Log network request
     */
    fun logNetwork(method: String, url: String, status: Int) {
        i("Network", "$method $url -> $status")
    }
}
