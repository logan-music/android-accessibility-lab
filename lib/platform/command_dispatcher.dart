import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/command_parser.dart';
import '../core/command_executor.dart';
import '../core/device_agent.dart';

/// CommandDispatcher: routes commands to executor; handles content:// URIs
class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  static const MethodChannel _channel = MethodChannel('cyber_accessibility_agent/commands');

  final CommandExecutor _executor = CommandExecutor.instance;

  /// Dispatch: if payload path is content:// -> handle native read+upload,
  /// otherwise forward to core executor.
  Future<Map<String, dynamic>> dispatch(Command cmd) async {
    final path = cmd.payload['path'];
    if (path is String && path.startsWith('content://') && Platform.isAndroid) {
      return _handleContentUriUpload(cmd, path);
    }
    return _executor.execute(cmd);
  }

  /// Public wrapper with retries/timeout
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 60),
    int maxRetries = 2,
  }) async {
    int attempt = 0;
    const baseDelayMs = 300;

    while (true) {
      attempt++;
      try {
        final res = await dispatch(cmd).timeout(timeout);
        return Map<String, dynamic>.from(res);
      } catch (e, st) {
        if (attempt > maxRetries) {
          return {'success': false, 'error': 'dispatcher_failed', 'detail': e.toString(), 'attempts': attempt};
        }
        final delayMs = baseDelayMs * (1 << (attempt - 1));
        await Future.delayed(Duration(milliseconds: delayMs > 5000 ? 5000 : delayMs));
      }
    }
  }

  /// Read content:// via platform channel, then upload bytes via DeviceAgent.uploadFile
  Future<Map<String, dynamic>> _handleContentUriUpload(Command cmd, String uri) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('readContentUri', {'uri': uri});
      if (raw == null || raw is! Map) return {'success': false, 'error': 'native_read_failed', 'detail': 'Invalid response'};
      final result = Map<String, dynamic>.from(raw);
      if (result['success'] != true) {
        return {'success': false, 'error': 'content_uri_read_failed', 'detail': result['error'] ?? result['detail']};
      }

      final String? b64 = (result['b64'] ?? result['file_b64'] ?? result['fileB64'])?.toString();
      final meta = result['meta'] ?? result['metadata'];
      final filename = (result['filename'] ?? (meta is Map ? meta['display_name'] ?? meta['name'] : null))?.toString() ??
          'content_${DateTime.now().millisecondsSinceEpoch}';
      final contentType = (result['content_type'] ?? (meta is Map ? meta['mime'] : null) ?? 'application/octet-stream').toString();

      if (b64 == null || b64.isEmpty) return {'success': false, 'error': 'no_file_bytes'};

      List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } catch (e) {
        return {'success': false, 'error': 'base64_decode_failed', 'detail': e.toString()};
      }

      final bucket = (cmd.payload['bucket'] as String?) ?? 'device-uploads';
      final dest = (cmd.payload['dest'] as String?) ?? filename;

      try {
        final uploadRes = await DeviceAgent.instance.uploadFile(
          path: filename,
          bytes: bytes,
          contentType: contentType,
          bucket: bucket,
          dest: dest,
        );
        if (uploadRes is Map<String, dynamic> && uploadRes['success'] == true) {
          return Map<String, dynamic>.from(uploadRes);
        }
        return {'success': false, 'error': uploadRes['error'] ?? 'upload_failed', 'detail': uploadRes};
      } catch (e) {
        return {'success': false, 'error': 'upload_exception', 'detail': e.toString()};
      }
    } catch (e) {
      return {'success': false, 'error': 'content_uri_exception', 'detail': e.toString()};
    }
  }
}