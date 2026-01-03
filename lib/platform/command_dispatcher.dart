// lib/platform/command_dispatcher.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/command_parser.dart';

/// Flutter-side dispatcher that forwards parsed Command objects to
/// the native layer via MethodChannel and returns a Map result.
///
/// Native side MUST implement a MethodChannel listener on:
///   "cyber_accessibility_agent/commands"
/// and support method name: "dispatch"
///
/// Expected args: a Map with keys: id, device_id, action, payload, created_at
class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/commands');

  /// Execute a command on the native side.
  ///
  /// - [cmd]: parsed Command object
  /// - [timeout]: how long to wait for a single native invocation attempt
  /// - [maxRetries]: number of retries on transient failures (0 = no retries)
  ///
  /// Returns a Map<String, dynamic> with at least {'success': bool}.
  /// If native returns a JSON string, we'll attempt to decode it.
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 0,
  }) async {
    final args = cmd.toMethodArgs();
    int attempt = 0;
    final baseDelayMs = 400; // for exponential backoff

    while (true) {
      attempt += 1;
      try {
        // invoke native method with a timeout for safety
        final raw = await _channel
            .invokeMethod<dynamic>('dispatch', args)
            .timeout(timeout);

        // normalize native response into Map<String, dynamic>
        final Map<String, dynamic> normalized = _normalizeNativeResult(raw);
        // ensure success key exists (default false)
        normalized.putIfAbsent('success', () => false);
        return normalized;
      } on TimeoutException {
        print('[CommandDispatcher] timeout on attempt $attempt for cmd=${cmd.id}');
        if (attempt > maxRetries) {
          return {'success': false, 'error': 'timeout', 'attempts': attempt};
        }
      } on PlatformException catch (pe) {
        // platform errors may include code/message/details
        print('[CommandDispatcher] PlatformException attempt $attempt: ${pe.code} ${pe.message}');
        if (attempt > maxRetries) {
          return {
            'success': false,
            'error': 'platform_exception',
            'code': pe.code,
            'message': pe.message,
            'details': pe.details,
            'attempts': attempt
          };
        }
      } catch (e) {
        print('[CommandDispatcher] unexpected error attempt $attempt: $e');
        if (attempt > maxRetries) {
          return {'success': false, 'error': 'exception', 'message': e.toString(), 'attempts': attempt};
        }
      }

      // backoff before next attempt
      final delay = Duration(milliseconds: baseDelayMs * (1 << (attempt - 1)));
      final capped = delay.inMilliseconds > 10000 ? Duration(milliseconds: 10000) : delay;
      await Future.delayed(capped);
    }
  }

  /// Normalize various possible native return types into Map<String,dynamic>
  /// Supported native responses:
  /// - Map (already correct)
  /// - JSON String -> decoded
  /// - bool -> { 'success': bool }
  /// - null -> { 'success': false }
  Map<String, dynamic> _normalizeNativeResult(dynamic raw) {
    if (raw == null) return {'success': false};
    if (raw is Map) {
      // ensure proper typing
      return Map<String, dynamic>.from(raw);
    }
    if (raw is bool) {
      return {'success': raw};
    }
    if (raw is String) {
      // try decode JSON
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        // if decoded into something else, wrap it
        return {'success': true, 'result': decoded};
      } catch (_) {
        // not JSON — return raw text
        return {'success': true, 'result_text': raw};
      }
    }
    // fallback: stringify
    try {
      return {'success': true, 'result': raw.toString()};
    } catch (_) {
      return {'success': false, 'error': 'unserializable_native_result'};
    }
  }
}