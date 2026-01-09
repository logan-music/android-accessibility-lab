import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/command_executor.dart';
import '../core/command_parser.dart';

class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/commands');

  final CommandExecutor _executor = CommandExecutor();

  /// MAIN ENTRY (used internally)
  Future<Map<String, dynamic>> dispatch(Command cmd) async {
    // CONTENT URI → Native Android
    final path = cmd.payload['path'];
    if (path is String && path.startsWith('content://')) {
      return _handleContentUriUpload(cmd, path);
    }

    // FILESYSTEM → Dart Executor
    return _executor.execute(cmd);
  }

  /// 🔥 THIS IS WHAT WAS MISSING
  /// Backward-compatible API used by device_agent.dart
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 2,
  }) async {
    int attempt = 0;

    while (true) {
      try {
        return await dispatch(cmd).timeout(timeout);
      } catch (e) {
        attempt++;
        if (attempt > maxRetries) {
          return {
            'success': false,
            'error': 'dispatcher_failed',
            'detail': e.toString(),
            'attempts': attempt,
          };
        }
      }
    }
  }

  /// CONTENT URI → Read via native → Upload
  Future<Map<String, dynamic>> _handleContentUriUpload(
      Command cmd, String uri) async {
    try {
      final result = await _channel.invokeMethod<Map>('readContentUri', {
        'uri': uri,
      });

      if (result == null || result['success'] != true) {
        return {
          'success': false,
          'error': 'content_uri_read_failed',
          'detail': result?['error']
        };
      }

      final payload = {
        'device_id': cmd.deviceId ?? '',
        'path': cmd.payload['dest'] ??
            result['filename'] ??
            'content_file',
        'file_b64': result['file_b64'],
        'content_type': result['content_type'] ?? 'application/octet-stream',
        'bucket': cmd.payload['bucket'] ?? 'device-uploads',
      };

      return await _upload(payload);
    } catch (e, st) {
      return {
        'success': false,
        'error': 'content_uri_exception',
        'detail': '$e\n$st'
      };
    }
  }

  /// HTTP upload to Supabase Edge Function
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
        return {'success': true, 'response': body};
      }
      return {'success': false, 'error': body};
    } finally {
      client.close(force: true);
    }
  }
}
