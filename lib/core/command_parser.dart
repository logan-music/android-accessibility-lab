// lib/core/command_parser.dart
import 'dart:convert';

class ParseResult {
  final Command? command;
  final String? error;
  ParseResult.ok(this.command) : error = null;
  ParseResult.err(this.error) : command = null;

  bool get isOk => command != null;
}

enum CommandAction {
  changeDir,
  listFiles,
  uploadFile,
  zipFiles,
  deleteFile,
  deviceInfo,
  ping,
  raw,
}

extension CommandActionExt on CommandAction {
  /// canonical action name expected by native layer
  String get name {
    switch (this) {
      case CommandAction.changeDir:
        return 'change_dir';
      case CommandAction.listFiles:
        return 'list_files';
      case CommandAction.uploadFile:
        return 'upload_file';
      case CommandAction.zipFiles:
        return 'zip_files';
      case CommandAction.deleteFile:
        return 'delete_file';
      case CommandAction.deviceInfo:
        return 'device_info';
      case CommandAction.ping:
        return 'ping';
      case CommandAction.raw:
        return 'raw';
    }
  }

  /// accepts aliases and maps to internal enum
  static CommandAction? fromString(String s) {
    final v = s.toLowerCase().trim();
    switch (v) {
      case 'cd':
      case 'change_dir':
        return CommandAction.changeDir;
      case 'list':
      case 'list_files':
      case 'ls':
        return CommandAction.listFiles;
      case 'upload':
      case 'upload_file':
      case 'send':
      case 'send_file':
        return CommandAction.uploadFile;
      case 'zip':
      case 'zip_files':
      case 'archive':
        return CommandAction.zipFiles;
      case 'delete':
      case 'delete_file':
      case 'rm':
      case 'remove':
        return CommandAction.deleteFile;
      case 'device_info':
      case 'info':
      case 'device':
        return CommandAction.deviceInfo;
      case 'ping':
      case 'ping_device':
        return CommandAction.ping;
      case 'raw':
        return CommandAction.raw;
      default:
        return null;
    }
  }
}

class Command {
  final String id;
  final String deviceId;
  final CommandAction action;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  Command({
    required this.id,
    required this.deviceId,
    required this.action,
    required this.payload,
    required this.createdAt,
  });

  /// Convert to sanitized map ready to send over MethodChannel
  Map<String, dynamic> toMethodArgs() {
    return {
      'id': id,
      'device_id': deviceId,
      'action': action.name,
      'payload': payload,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

/// Lightweight rate limiter: allows up to `maxCalls` per `windowSeconds`
/// per (deviceId + action) key. Not cryptographically secure; for lab only.
class SimpleRateLimiter {
  final int maxCalls;
  final int windowSeconds;
  final Map<String, List<int>> _timestamps = {};

  SimpleRateLimiter({this.maxCalls = 10, this.windowSeconds = 60});

  String _key(String deviceId, String action) => '$deviceId|$action';

  bool allow(String deviceId, String action) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = _key(deviceId, action);
    final list = _timestamps.putIfAbsent(key, () => []);
    // remove old
    list.removeWhere((ts) => ts <= now - windowSeconds);
    if (list.length >= maxCalls) return false;
    list.add(now);
    return true;
  }
}

class CommandParser {
  // Config knobs
  static const int _maxPathLength = 1024;
  static const int _maxPayloadKeys = 40;
  static const int _maxIdLength = 128;
  static const int _maxZipNameLength = 128;
  static final SimpleRateLimiter _rateLimiter = SimpleRateLimiter(maxCalls: 12, windowSeconds: 30);

  /// Parse a raw DB row (Map) coming from DeviceAgent._handleCommand
  /// `raw` is expected to contain keys: id, device_id, action, payload, created_at
  static ParseResult parse(Map<String, dynamic> raw, String expectedDeviceId) {
    try {
      // Basic existence checks
      final id = raw['id']?.toString();
      final deviceId = raw['device_id']?.toString() ?? raw['deviceId']?.toString();
      String? actionRaw = raw['action']?.toString();
      final payloadRaw = raw['payload'];
      final createdAtRaw = raw['created_at'] ?? raw['createdAt'];

      if (id == null || id.isEmpty) return ParseResult.err('missing id');
      if (id.length > _maxIdLength) return ParseResult.err('id too long');
      if (deviceId == null || deviceId.isEmpty) return ParseResult.err('missing device_id');
      if (deviceId != expectedDeviceId) return ParseResult.err('device_id mismatch');

      // If action is not provided, try to derive from legacy 'command' text
      if (actionRaw == null || actionRaw.trim().isEmpty) {
        final legacy = raw['command'] ?? raw['cmd'] ?? raw['command_text'];
        if (legacy != null) {
          final derived = _deriveActionFromCommandText(legacy.toString());
          actionRaw = derived['action'];
          // we'll merge derived payload later
        } else {
          return ParseResult.err('missing action');
        }
      }

      final actionEnum = CommandActionExt.fromString(actionRaw!);
      if (actionEnum == null) return ParseResult.err('unknown action: $actionRaw');

      // Rate limit
      if (!_rateLimiter.allow(deviceId, actionEnum.name)) {
        return ParseResult.err('rate_limited');
      }

      // Payload normalization
      Map<String, dynamic> payload = {};
      if (payloadRaw != null) {
        if (payloadRaw is String) {
          try {
            final decoded = jsonDecode(payloadRaw);
            if (decoded is Map) {
              payload = Map<String, dynamic>.from(decoded);
            } else {
              payload = {'value': decoded};
            }
          } catch (_) {
            payload = {'value': payloadRaw};
          }
        } else if (payloadRaw is Map) {
          payload = Map<String, dynamic>.from(payloadRaw);
        } else {
          payload = {'value': payloadRaw};
        }
      }

      // If legacy command text present, merge its payload without overwriting explicit payload keys
      final legacyCmdText = (raw['command'] ?? raw['cmd']);
      if (legacyCmdText != null) {
        final derived = _deriveActionFromCommandText(legacyCmdText.toString());
        if (derived['payload'] is Map) {
          (derived['payload'] as Map).forEach((k, v) {
            payload.putIfAbsent(k, () => v);
          });
        }
      }

      // Basic payload size check
      if (payload.length > _maxPayloadKeys) return ParseResult.err('payload too large');

      // Action-specific validation and sanitization
      switch (actionEnum) {
        case CommandAction.changeDir:
          return _parseChangeDir(id, deviceId, payload, createdAtRaw);
        case CommandAction.listFiles:
          return _parseListFiles(id, deviceId, payload, createdAtRaw);
        case CommandAction.uploadFile:
          return _parseUploadFile(id, deviceId, payload, createdAtRaw);
        case CommandAction.zipFiles:
          return _parseZipFiles(id, deviceId, payload, createdAtRaw);
        case CommandAction.deleteFile:
          return _parseDeleteFile(id, deviceId, payload, createdAtRaw);
        case CommandAction.deviceInfo:
          return _parseDeviceInfo(id, deviceId, payload, createdAtRaw);
        case CommandAction.ping:
          return _parsePing(id, deviceId, payload, createdAtRaw);
        case CommandAction.raw:
          final createdAt = _parseDate(createdAtRaw);
          final cmd = Command(
            id: id,
            deviceId: deviceId,
            action: CommandAction.raw,
            payload: {'text': payload['value'] ?? ''},
            createdAt: createdAt,
          );
          return ParseResult.ok(cmd);
      }
    } catch (e) {
      return ParseResult.err('exception: $e');
    }
  }

  // -------------------------
  // Individual action parsers
  // -------------------------

  static ParseResult _parseChangeDir(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final path = _extractString(payload, ['path', 'dir', 'directory', 'target']);
    if (path == null || path.isEmpty) return ParseResult.err('cd requires path');
    if (path.length > _maxPathLength) return ParseResult.err('path too long');
    final createdAt = _parseDate(createdAtRaw);

    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.changeDir,
      payload: {'path': path},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseListFiles(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final path = _extractString(payload, ['path', 'dir', 'directory']) ?? '/storage/emulated/0/';
    if (path.length > _maxPathLength) return ParseResult.err('path too long');
    final recursive = payload['recursive'] == true || payload['recursive'] == 'true';
    final limitRaw = payload['limit'] ?? payload['max'] ?? 100;
    final limit = (limitRaw is int) ? limitRaw : (int.tryParse('$limitRaw') ?? 100);
    final createdAt = _parseDate(createdAtRaw);

    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.listFiles,
      payload: {'path': path, 'recursive': recursive, 'limit': limit},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseUploadFile(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final path = _extractString(payload, ['path', 'file', 'filepath', 'src']);
    final bucket = _extractString(payload, ['bucket', 'storage_bucket']) ?? '';
    final dest = _extractString(payload, ['dest', 'destination', 'key']) ?? '';
    if (path == null || path.isEmpty) return ParseResult.err('upload_file requires path');
    if (path.length > _maxPathLength) return ParseResult.err('path too long');
    final createdAt = _parseDate(createdAtRaw);

    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.uploadFile,
      payload: {'path': path, if (bucket.isNotEmpty) 'bucket': bucket, if (dest.isNotEmpty) 'dest': dest},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseZipFiles(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final path = _extractString(payload, ['path', 'dir', 'directory']);
    final zipName = _extractString(payload, ['zip_name', 'zip', 'archive']) ?? 'archive.zip';
    if (path == null || path.isEmpty) return ParseResult.err('zip_files requires path');
    if (path.length > _maxPathLength) return ParseResult.err('path too long');
    if (zipName.length > _maxZipNameLength) return ParseResult.err('zip_name too long');
    final createdAt = _parseDate(createdAtRaw);

    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.zipFiles,
      payload: {'path': path, 'zip_name': zipName},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseDeleteFile(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final path = _extractString(payload, ['path', 'file', 'filepath', 'target']);
    if (path == null || path.isEmpty) return ParseResult.err('delete_file requires path');
    if (path.length > _maxPathLength) return ParseResult.err('path too long');
    final permanent = payload['permanent'] == true || payload['permanent'] == 'true';
    final createdAt = _parseDate(createdAtRaw);

    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.deleteFile,
      payload: {'path': path, 'permanent': permanent},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseDeviceInfo(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.deviceInfo,
      payload: {},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parsePing(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.ping,
      payload: {},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  // -------------------------
  // Helper utilities
  // -------------------------

  static String? _extractString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      if (!m.containsKey(k)) continue;
      final v = m[k];
      if (v == null) continue;
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) continue;
        return s;
      }
      if (v is num) return v.toString();
      try {
        final s = v.toString();
        if (s.isNotEmpty) return s;
      } catch (_) {}
    }
    return null;
  }

  static DateTime _parseDate(dynamic raw) {
    if (raw == null) return DateTime.now().toUtc();
    if (raw is DateTime) return raw.toUtc();
    final s = raw.toString();
    try {
      return DateTime.parse(s).toUtc();
    } catch (_) {
      return DateTime.now().toUtc();
    }
  }

  static Map<String, dynamic> _deriveActionFromCommandText(String cmdText) {
    final raw = cmdText.trim();
    if (raw.isEmpty) return {'action': 'raw', 'payload': {}};

    final parts = raw.split(RegExp(r'\s+'));
    var first = parts[0];
    if (first.startsWith('/')) first = first.substring(1);
    final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    switch (first.toLowerCase()) {
      case 'cd':
        // /cd <path>
        return {'action': 'change_dir', 'payload': {'path': args}};
      case 'pwd':
        return {'action': 'list_files', 'payload': {'path': ''}}; // pwd handled by executor (no path change)
      case 'list':
      case 'ls':
        return {
          'action': 'list_files',
          'payload': {'path': args.isNotEmpty ? args : '/storage/emulated/0/'}
        };
      case 'upload':
      case 'send':
        return {
          'action': 'upload_file',
          'payload': {'path': args.isNotEmpty ? args : null}
        };
      case 'zip':
      case 'archive':
        // usage: /zip <path> [zip_name]
        final sub = args.split(RegExp(r'\s+'));
        final p = sub.isNotEmpty ? sub[0] : '';
        final z = (sub.length > 1) ? sub.sublist(1).join('_') : 'archive.zip';
        return {'action': 'zip_files', 'payload': {'path': p, 'zip_name': z}};
      case 'delete':
      case 'rm':
        return {'action': 'delete_file', 'payload': {'path': args}};
      case 'info':
      case 'device_info':
        return {'action': 'device_info', 'payload': {}};
      case 'ping':
        return {'action': 'ping', 'payload': {}};
      default:
        return {'action': 'raw', 'payload': {'text': raw}};
    }
  }
}