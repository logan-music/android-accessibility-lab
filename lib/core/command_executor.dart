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

  Future<Map<String, dynamic>> execute(Command cmd) async {
    try {
      switch (cmd.action) {
        case CommandAction.changeDir:
          return _wrapSync(() => _cd(cmd.payload['path'] as String?));
        case CommandAction.listFiles:
          return _wrapSync(() => _ls(
                cmd.payload['path'] as String?,
                recursive: cmd.payload['recursive'] == true,
                limit: cmd.payload['limit'] is int ? cmd.payload['limit'] : 100,
              ));
        case CommandAction.deleteFile:
          return _wrapSync(() => _rm(cmd.payload['path'] as String?));
        case CommandAction.uploadFile:
          return await _uploadFileSystem(
            cmd.payload['path'] as String?,
            deviceId: cmd.deviceId,
            bucket: cmd.payload['bucket'] as String?,
            dest: cmd.payload['dest'] as String?,
          );
        case CommandAction.deviceInfo:
          // return richer device info gathered via helper (calls native ping when available)
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
  /// Reads the file from fs then delegates upload to DeviceAgent.instance.uploadFile
  Future<Map<String, dynamic>> _uploadFileSystem(
    String? path, {
    String? deviceId,
    String? bucket,
    String? dest,
  }) async {
    if (path == null || path.isEmpty) return _err('upload_requires_file', 'upload requires path');

    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _err('access_denied', 'path outside storage root');

    final file = File(target);
    if (!file.existsSync()) return _err('file_not_found', target);

    try {
      final bytes = await file.readAsBytes();
      final filename = (dest != null && dest.isNotEmpty) ? dest : file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';

      // Delegate to DeviceAgent (multipart POST to edge function)
      final res = await DeviceAgent.instance.uploadFile(
        path: filename,
        bytes: bytes,
        contentType: contentType,
        bucket: bucket ?? _defaultBucket,
        dest: filename,
      );

      // normalize response shape
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

/// Helper to collect device info for /info command
class DeviceInfoHelper {
  // reuse existing commands channel (MainActivity already handles 'ping')
  static const MethodChannel _channel = MethodChannel('cyber_accessibility_agent/commands');

  /// Returns a map shaped to match what the bot/index.js expects:
  /// keys: brand, model, device, manufacturer, android_version, sdk, is_physical_device, cwd
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

    // Try to get model from native 'ping' if implemented (MainActivity currently returns Build.MODEL on ping)
    try {
      final res = await _channel.invokeMethod<dynamic>('ping');
      if (res is Map) {
        // MainActivity returns { status: "ok", device: Build.MODEL }
        info['model'] = (res['device'] ?? res['model'] ?? res['device_model'])?.toString();
      } else if (res is Map<dynamic, dynamic>) {
        info['model'] = (res['device'] ?? res['model'])?.toString();
      }
    } catch (_) {
      // ignore - fallback to null
    }

    // Mark unknown fields explicitly as null so bot can safely handle them
    return info;
  }
}