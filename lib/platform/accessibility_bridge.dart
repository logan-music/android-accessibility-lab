// lib/platform/accessibility_bridge.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import '../core/command_parser.dart';

/// AccessibilityBridge
/// - Singleton wrapper around MethodChannel / EventChannel
/// - Queues commands so only one native invocation runs at a time
/// - Provides timeout, retry, exponential backoff
/// - Normalizes native responses into Map<String, dynamic>
class AccessibilityBridge {
  AccessibilityBridge._internal() {
    _initEventStream();
  }
  static final AccessibilityBridge _instance = AccessibilityBridge._internal();
  factory AccessibilityBridge() => _instance;

  // Channel names must match Android native implementation
  static const MethodChannel _methodChannel = MethodChannel('accessibility_bridge');
  static const EventChannel _eventChannel = EventChannel('accessibility_events');

  // Internal queue to serialize native calls.
  // Start with resolved future so first enqueue executes immediately.
  Future<void> _queue = Future<void>.value();

  // Event stream controller (broadcast)
  StreamController<Map<String, dynamic>>? _eventsController;

  // Initialize EventChannel → StreamController
  void _initEventStream() {
    if (_eventsController != null && !_eventsController!.isClosed) return;
    _eventsController = StreamController<Map<String, dynamic>>.broadcast(onListen: () {
      // nothing special on listen
    }, onCancel: () {
      // keep controller for future re-use
    });

    try {
      _eventChannel.receiveBroadcastStream().listen((dynamic raw) {
        try {
          if (raw == null) return;
          if (raw is Map) {
            _eventsController?.add(Map<String, dynamic>.from(raw));
          } else if (raw is String) {
            final parsed = _tryParseJson(raw);
            if (parsed != null) {
              _eventsController?.add(parsed);
            } else {
              // if it's a plain string event, wrap it
              _eventsController?.add({'event': 'message', 'data': raw});
            }
          } else {
            // try to convert to JSON via toString()
            final parsed = _tryParseJson(raw.toString());
            if (parsed != null) _eventsController?.add(parsed);
            else _eventsController?.add({'event': 'message', 'data': raw.toString()});
          }
        } catch (e) {
          // forward as error event map but do not close stream
          _eventsController?.add({'event': 'error', 'error': e.toString()});
        }
      }, onError: (err) {
        _eventsController?.add({'event': 'error', 'error': err?.toString() ?? 'unknown_event_error'});
      });
    } catch (e) {
      // if EventChannel listen fails, emit an error event
      _eventsController?.add({'event': 'error', 'error': 'event_channel_init_failed: ${e.toString()}'});
    }
  }

  /// Public: stream of events emitted from native AccessibilityService (optional).
  Stream<Map<String, dynamic>> get events {
    _initEventStream();
    return _eventsController!.stream;
  }

  // -------------------------
  // High-level execute API
  // -------------------------

  /// Execute a command (safe wrapper). This method will:
  ///  - enqueue the call (serialize)
  ///  - attempt up to [maxRetries] times with exponential backoff
  ///  - apply [timeout] per attempt
  ///
  /// Returns a normalized Map with at least `{'success': bool, ...}`.
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 2,
    Duration initialBackoff = const Duration(milliseconds: 300),
  }) {
    return _enqueue<Map<String, dynamic>>(() => _doExecute(cmd, timeout, maxRetries, initialBackoff));
  }

  /// Convenience that returns boolean success only.
  Future<bool> executeCommandBool(Command cmd, {Duration timeout = const Duration(seconds: 10), int maxRetries = 2}) async {
    final res = await executeCommand(cmd, timeout: timeout, maxRetries: maxRetries);
    return (res['success'] == true);
  }

  // -------------------------
  // Internal helpers
  // -------------------------

  Future<Map<String, dynamic>> _doExecute(
    Command cmd,
    Duration timeout,
    int maxRetries,
    Duration initialBackoff,
  ) async {
    final args = cmd.toMethodArgs();
    int attempt = 0;
    Duration backoff = initialBackoff;

    while (true) {
      attempt++;
      try {
        final dynamic rawResult = await _methodChannel.invokeMethod('executeCommand', args).timeout(timeout);

        final Map<String, dynamic> normalized = _normalizeResult(rawResult);
        // attach attempt metadata (useful for debugging)
        normalized['attempt'] = attempt;
        normalized['cmd_id'] = cmd.id;
        return normalized;
      } on PlatformException catch (pe) {
        if (attempt > maxRetries) {
          return {'success': false, 'error': 'PlatformException', 'message': pe.message ?? pe.code, 'attempts': attempt};
        }
        await Future.delayed(backoff);
        backoff = backoff * 2;
        continue;
      } on TimeoutException {
        if (attempt > maxRetries) {
          return {'success': false, 'error': 'timeout', 'attempts': attempt};
        }
        await Future.delayed(backoff);
        backoff = backoff * 2;
        continue;
      } catch (e) {
        // Unknown error
        return {'success': false, 'error': 'exception', 'message': e.toString(), 'attempts': attempt};
      }
    }
  }

  // Serialize calls to avoid overlapping native invocations
  Future<T> _enqueue<T>(Future<T> Function() fn) {
    final completer = Completer<T>();

    // chain onto the queue
    _queue = _queue.then((_) async {
      try {
        final result = await fn();
        if (!completer.isCompleted) completer.complete(result as T);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  // Normalize various native return types into Map<String, dynamic>
  Map<String, dynamic> _normalizeResult(dynamic raw) {
    if (raw == null) return {'success': false, 'info': 'null_result'};
    if (raw is bool) return {'success': raw};
    if (raw is Map) {
      // ensure Map<String,dynamic>
      try {
        return Map<String, dynamic>.from(raw);
      } catch (_) {
        // fallback: convert each key to string
        final map = <String, dynamic>{};
        raw.forEach((k, v) {
          map[k.toString()] = v;
        });
        return map;
      }
    }
    if (raw is String) {
      final parsed = _tryParseJson(raw);
      if (parsed != null) return parsed;
      // if it's a simple "true"/"false" string
      final low = raw.toLowerCase().trim();
      if (low == 'true') return {'success': true};
      if (low == 'false') return {'success': false};
      return {'success': false, 'info': raw};
    }
    // fallback
    return {'success': false, 'info': raw.toString()};
  }

  Map<String, dynamic>? _tryParseJson(String s) {
    try {
      final dynamic decoded = s.isEmpty ? null : jsonDecode(s);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Dispose event stream (call during app shutdown if desired)
  void dispose() {
    try {
      _eventsController?.close();
    } catch (_) {}
    _eventsController = null;
  }
}