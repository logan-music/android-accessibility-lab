// lib/app_logger.dart
// Production-safe logger that works WITHOUT path_provider dependency
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/**
 * Production-safe in-app logger for Dart/Flutter.
 * Writes to same file as Kotlin logger for unified logging.
 * NEVER crashes the app - all errors silently ignored.
 */
class AppLogger {
  static const String _logFileName = 'app_log.txt';
  static const int _maxLogSize = 5 * 1024 * 1024; // 5MB
  
  static File? _logFile;
  static bool _initialized = false;
  static final _writeQueue = <String>[];
  static bool _isWriting = false;
  
  /// Initialize logger. Call in main() before runApp().
  static Future<void> init() async {
    if (_initialized) return;
    
    try {
      // ✅ FIX: Use hardcoded path instead of path_provider
      // This matches exactly where Kotlin AppLogger writes
      String? logPath;
      
      if (Platform.isAndroid) {
        // Same path as Kotlin: /data/data/package_name/files/app_log.txt
        final appDir = Directory('/data/data/com.example.cyber_accessibility_agent/files');
        
        if (!await appDir.exists()) {
          await appDir.create(recursive: true);
        }
        
        logPath = '${appDir.path}/$_logFileName';
      } else {
        // For other platforms, use current directory
        logPath = _logFileName;
      }
      
      _logFile = File(logPath);
      
      // Create file if doesn't exist
      if (!await _logFile!.exists()) {
        await _logFile!.create(recursive: true);
      }
      
      _initialized = true;
      
      // Write initialization marker
      i('AppLogger', '=== Dart logger initialized: ${_logFile!.path} ===');
      i('AppLogger', 'Flutter app started at: ${DateTime.now().toIso8601String()}');
      
    } catch (e) {
      // Silent failure - don't crash app
      debugPrint('AppLogger init failed: $e');
    }
  }
  
  /// Info level log
  static void i(String tag, String message) {
    _log('INFO', tag, message, null);
  }
  
  /// Debug level log
  static void d(String tag, String message) {
    _log('DEBUG', tag, message, null);
  }
  
  /// Warning level log
  static void w(String tag, String message) {
    _log('WARN', tag, message, null);
  }
  
  /// Error level log
  static void e(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    _log('ERROR', tag, message, error, stackTrace);
  }
  
  /// Critical error - always logged
  static void critical(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    _log('CRITICAL', tag, message, error, stackTrace);
  }
  
  /// Internal logging logic
  static void _log(String level, String tag, String message, 
                   [dynamic error, StackTrace? stackTrace]) {
    // Also print to console for development
    final logMessage = '[$level] [$tag] $message';
    
    if (kDebugMode) {
      if (error != null) {
        debugPrint('$logMessage\n  Error: $error');
      } else {
        debugPrint(logMessage);
      }
    }
    
    if (!_initialized || _logFile == null) return;
    
    // Queue the log entry
    _queueLogEntry(level, tag, message, error, stackTrace);
  }
  
  /// Queue log entry for async writing
  static void _queueLogEntry(String level, String tag, String message,
                             dynamic error, StackTrace? stackTrace) {
    try {
      final timestamp = DateTime.now().toIso8601String();
      final logEntry = StringBuffer();
      logEntry.writeln('[$timestamp] [$level] [$tag] $message');
      
      // Add error if present
      if (error != null) {
        logEntry.writeln('  Error: $error');
      }
      
      // Add stack trace if present
      if (stackTrace != null) {
        final lines = stackTrace.toString().split('\n').take(10);
        for (final line in lines) {
          if (line.trim().isNotEmpty) {
            logEntry.writeln('    $line');
          }
        }
      }
      
      _writeQueue.add(logEntry.toString());
      
      // Process queue if not already writing
      if (!_isWriting) {
        _processQueue();
      }
      
    } catch (e) {
      // Silent failure
      debugPrint('AppLogger queue error: $e');
    }
  }
  
  /// Process write queue asynchronously
  static Future<void> _processQueue() async {
    if (_isWriting || _writeQueue.isEmpty) return;
    
    _isWriting = true;
    
    try {
      final file = _logFile;
      if (file == null) return;
      
      // Check file size and rotate if needed
      if (await file.exists()) {
        final length = await file.length();
        if (length > _maxLogSize) {
          await _rotateLog(file);
        }
      }
      
      // Write all queued entries
      final entries = List<String>.from(_writeQueue);
      _writeQueue.clear();
      
      final sink = file.openWrite(mode: FileMode.append);
      
      for (final entry in entries) {
        sink.write(entry);
      }
      
      await sink.flush();
      await sink.close();
      
    } catch (e) {
      // Silent failure
      debugPrint('AppLogger write error: $e');
    } finally {
      _isWriting = false;
      
      // Process remaining queue if any
      if (_writeQueue.isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 100), _processQueue);
      }
    }
  }
  
  /// Rotate log file when too large
  static Future<void> _rotateLog(File file) async {
    try {
      final backupFile = File('${file.path}.old');
      
      // Delete old backup
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      
      // Rename current to backup
      await file.rename(backupFile.path);
      
      // Create new log file
      await file.create();
      
      final sink = file.openWrite();
      sink.writeln('=== Log rotated at ${DateTime.now().toIso8601String()} ===');
      await sink.flush();
      await sink.close();
      
    } catch (e) {
      // If rotation fails, just clear the file
      try {
        final sink = file.openWrite(mode: FileMode.write);
        sink.writeln('=== Log cleared (rotation failed) at ${DateTime.now().toIso8601String()} ===');
        await sink.flush();
        await sink.close();
      } catch (e2) {
        // Give up silently
        debugPrint('Log rotation failed: $e2');
      }
    }
  }
  
  /// Get log file path
  static String? getLogFilePath() {
    return _logFile?.path;
  }
  
  /// Get log file content (last N lines)
  static Future<String> getLogContent({int lastLines = 500}) async {
    try {
      final file = _logFile;
      if (file == null) return 'Log file not initialized';
      
      if (!await file.exists()) {
        return 'Log file does not exist';
      }
      
      final lines = await file.readAsLines();
      final startIndex = lines.length > lastLines ? lines.length - lastLines : 0;
      
      return lines.sublist(startIndex).join('\n');
      
    } catch (e) {
      return 'Error reading log: $e';
    }
  }
  
  /// Clear log file
  static Future<void> clearLog() async {
    try {
      final file = _logFile;
      if (file == null) return;
      
      final sink = file.openWrite(mode: FileMode.write);
      sink.writeln('=== Log cleared at ${DateTime.now().toIso8601String()} ===');
      await sink.flush();
      await sink.close();
      
    } catch (e) {
      debugPrint('Failed to clear log: $e');
    }
  }
  
  /// Log lifecycle event
  static void logLifecycle(String event) {
    i('Lifecycle', '>>> $event <<<');
  }
  
  /// Log command execution
  static void logCommand(String commandId, String action, String status) {
    i('Command', '[$commandId] $action -> $status');
  }
  
  /// Log network request
  static void logNetwork(String method, String url, int status) {
    i('Network', '$method $url -> $status');
  }
  
  /// Log async operation start
  static void logAsyncStart(String operation) {
    d('Async', 'START: $operation');
  }
  
  /// Log async operation complete
  static void logAsyncComplete(String operation, {Duration? duration}) {
    if (duration != null) {
      d('Async', 'COMPLETE: $operation (${duration.inMilliseconds}ms)');
    } else {
      d('Async', 'COMPLETE: $operation');
    }
  }
  
  /// Log async operation error
  static void logAsyncError(String operation, dynamic error, [StackTrace? stackTrace]) {
    e('Async', 'ERROR: $operation', error, stackTrace);
  }
}
