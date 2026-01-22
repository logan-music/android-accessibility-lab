// lib/core/command_executor.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'command_parser.dart';
import 'device_agent.dart';

/// CommandExecutor: performs filesystem ops on-device and can upload files
/// using DeviceAgent.instance.uploadFile (multipart to edge function / Supabase).
class CommandExecutor {
  CommandExecutor._();
  static final CommandExecutor instance = CommandExecutor._();

  static const String _root = '/storage/emulated/0';
  static const String _defaultBucket = 'device-uploads';

  String _cwd = _root;
  String get cwd => _cwd;

  String _normalize(String path) {
    if (path.length > 1 && path.endsWith('/')) return path.substring(0, path.length - 1);
    return path;
  }

  String _resolvePath(String input) {
    if (input == null || input.isEmpty) return _cwd;
    final p = input;
    if (p.startsWith('/')) return _normalize(p);
    if (p == '..') {
      if (_cwd == _root) return _root;
      final i = _cwd.lastIndexOf('/');
      return i > _root.length ? _cwd.substring(0, i) : _root;
    }
    return _normalize('$_cwd/$p');
  }

  bool _isInsideRoot(String path) => path == _root || path.startsWith('$_root/');

  final MethodChannel _native = const MethodChannel('cyber_accessibility_agent/commands');

  Future<Map<String, dynamic>> execute(Command cmd) async {
    try {
      switch (cmd.action) {
        case CommandAction.changeDir:
          return _wrapSync(() => _cd(cmd.payload['path'] as String?));
        case CommandAction.listFiles:
          return _wrapSync(() => _ls(cmd.payload['path'] as String?, recursive: cmd.payload['recursive'] == true, limit: cmd.payload['limit'] is int ? cmd.payload['limit'] : 100));
        case CommandAction.deleteFile:
          return _wrapSync(() => _rm(cmd.payload['path'] as String?));
        case CommandAction.deleteDir:
          return _wrapSync(() => _rm(cmd.payload['path'] as String?)); // _rm already supports directory recursive delete
        case CommandAction.uploadFile:
          return await _uploadFileSystem(cmd.payload['path'] as String?, deviceId: cmd.deviceId, bucket: cmd.payload['bucket'] as String?, dest: cmd.payload['dest'] as String?);
        case CommandAction.prepareUpload:
          return await _prepareUpload((cmd.payload['path'] as String?));
        case CommandAction.readFile:
          return await _readFile(path: (cmd.payload['path'] as String?) ?? (cmd.payload['uri'] as String?));
        case CommandAction.deviceInfo:
          final info = await DeviceInfoHelper.getDeviceInfo(cwd: _cwd);
          return _ok(info);
        case CommandAction.ping:
          return _ok({'ts': DateTime.now().toUtc().toIso8601String()});
        default:
          return _err('unsupported_action', 'Action not supported by executor');
      }
    } catch (e, st) {
      return _err('exception', '$e\n$st');
    }
  }

  // ---------------- FILESYSTEM OPS ----------------

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

    final List<Map<String, dynamic>> entries = [];

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
          if (recursive && stat.type == FileSystemEntityType.directory) {
            walk(Directory(e.path));
          }
        } catch (_) {}
      }
    }

    walk(dir);
    return _ok({'cwd': _cwd, 'count': entries.length, 'entries': entries});
  }

  Map<String, dynamic> _rm(String? path) {
    if (path == null || path.isEmpty) return _err('rm_requires_file', 'rm requires file path');
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

    try {
      final f = File(target);
      final d = Directory(target);
      if (f.existsSync()) {
        f.deleteSync();
        return _ok({'deleted': target, 'type': 'file'});
      } else if (d.existsSync()) {
        d.deleteSync(recursive: true);
        return _ok({'deleted': target, 'type': 'directory'});
      }
      return _err('not_found', target);
    } catch (e, st) {
      return _err('delete_failed', '$e\n$st');
    }
  }

  // ---------------- UPLOAD (FILESYSTEM: read bytes then upload) ----------------
  Future<Map<String, dynamic>> _uploadFileSystem(String? path, {String? deviceId, String? bucket, String? dest}) async {
    if (path == null || path.isEmpty) return _err('upload_requires_file', 'upload requires path');

    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

    final file = File(target);
    if (!file.existsSync()) return _err('file_not_found', target);

    try {
      final bytes = await file.readAsBytes();
      final filename = (dest != null && dest.isNotEmpty) ? dest : file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';

      final res = await DeviceAgent.instance.uploadFile(
        path: filename,
        bytes: bytes,
        contentType: contentType,
        bucket: bucket ?? _defaultBucket,
        dest: filename,
      );

      if (res is Map<String, dynamic>) {
        if (res['success'] == true) {
          return _ok({'file': file.path, 'upload': res});
        } else {
          return _err('upload_failed', res.toString());
        }
      } else {
        return _ok({'file': file.path, 'upload_response': res});
      }
    } catch (e, st) {
      return _err('upload_exception', '$e\n$st');
    }
  }

  /// Prepare upload: lightweight metadata-only check so server decides next steps.
  /// Returns shape like:
  /// { is_content_uri: true, uri: 'content://...', name: 'IMG.jpg' }
  /// or
  /// { is_content_uri: false, path: '/storage/emulated/0/DCIM/IMG.jpg', name: 'IMG.jpg', size: 12345 }
  Future<Map<String, dynamic>> _prepareUpload(String? path) async {
    if (path == null || path.isEmpty) return _err('prepare_requires_path', 'prepare_upload requires path/uri');

    try {
      // content uri -> don't read bytes here, just report meta
      if (path.startsWith('content://') && Platform.isAndroid) {
        try {
          // Try to fetch lightweight meta via native (if available)
          final Map<dynamic, dynamic>? meta = await _native.invokeMethod<dynamic>('getContentUriMeta', {'uri': path}) as Map<dynamic, dynamic>?;
          if (meta != null && meta.isNotEmpty) {
            return _ok({
              'is_content_uri': true,
              'uri': path,
              'meta': Map<String, dynamic>.from(meta.map((k, v) => MapEntry(k.toString(), v))),
              'name': (meta['display_name'] ?? meta['name'])?.toString(),
            });
          }
        } catch (_) {
          // ignore - fallback
        }

        // Best-effort guess at filename from URI (last segment)
        final parts = path.split('/');
        final name = parts.isNotEmpty ? parts.last : 'content';
        return _ok({'is_content_uri': true, 'uri': path, 'name': name});
      }

      // filesystem path
      final target = _resolvePath(path);
      if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

      final file = File(target);
      if (!file.existsSync()) return _err('file_not_found', target);

      final stat = file.statSync();
      final filename = file.path.split('/').last;
      return _ok({
        'is_content_uri': false,
        'path': target,
        'name': filename,
        'size': stat.size,
        'modified': stat.modified.toUtc().toIso8601String(),
      });
    } catch (e, st) {
      return _err('prepare_exception', '$e\n$st');
    }
  }

  /// Read file or content URI and return base64 result expected by edge `upload-file`.
  Future<Map<String, dynamic>> _readFile({String? path}) async {
    if (path == null || path.isEmpty) return _err('read_requires_path', 'read_file requires path or uri');

    try {
      if (path.startsWith('content://') && Platform.isAndroid) {
        try {
          final Map<dynamic, dynamic>? raw = await _native.invokeMethod<dynamic>('readContentUri', {'uri': path}) as Map<dynamic, dynamic>?;
          if (raw == null) return _err('native_read_failed', 'empty native response');

          final b64 = (raw['b64'] ?? raw['file_b64'] ?? raw['fileB64'])?.toString();
          final filename = (raw['filename'] ?? raw['file_name'] ?? raw['name'])?.toString();
          final contentType = (raw['content_type'] ?? raw['mime'] ?? raw['contentType'])?.toString();
          final size = raw['size'];

          if (b64 == null || b64.isEmpty) return _err('no_file_bytes', raw.toString());

          return _ok({
            'file_b64': b64,
            if (filename != null) 'filename': filename,
            if (contentType != null) 'content_type': contentType,
            if (size != null) 'size': size,
          });
        } catch (e, st) {
          return _err('native_read_exception', '$e\n$st');
        }
      }

      final target = _resolvePath(path);
      if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

      final file = File(target);
      if (!file.existsSync()) return _err('file_not_found', target);

      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      final filename = file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';
      return _ok({
        'file_b64': b64,
        'filename': filename,
        'content_type': contentType,
        'size': bytes.length,
      });
    } catch (e, st) {
      return _err('read_exception', '$e\n$st');
    }
  }

  String? _guessContentType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'mp4':
        return 'video/mp4';
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'zip':
        return 'application/zip';
    }
    return null;
  }

  // ---------------- HELPERS ----------------

  Map<String, dynamic> _ok([Map<String, dynamic>? data]) => {'success': true, if (data != null) 'result': data};

  Map<String, dynamic> _err(String code, [String? detail]) => {'success': false, 'error': code, if (detail != null) 'detail': detail};

  Map<String, dynamic> _wrapSync(Map<String, dynamic> Function() fn) {
    try {
      return fn();
    } catch (e, st) {
      return _err('exception', '$e\n$st');
    }
  }
}

/// DeviceInfoHelper unchanged (keep same as earlier)...
class DeviceInfoHelper {
  static const MethodChannel _channel = MethodChannel('cyber_accessibility_agent/commands');

  static Future<Map<String, dynamic>> getDeviceInfo({String cwd = '/storage/emulated/0/'}) async {
    final Map<String, dynamic> info = {
      'brand': null,
      'model': null,
      'device': null,
      'manufacturer': null,
      'android_version': Platform.isAndroid ? Platform.operatingSystemVersion : Platform.operatingSystem,
      'sdk': null,
      'is_physical_device': true,
      'cwd': cwd,
    };

    try {
      final res = await _channel.invokeMethod<dynamic>('ping');
      if (res is Map) {
        info['model'] = (res['device'] ?? res['model'] ?? res['device_model'])?.toString();
      } else if (res is Map<dynamic, dynamic>) {
        info['model'] = (res['device'] ?? res['model'])?.toString();
      }
    } catch (_) {}

    return info;
  }
}