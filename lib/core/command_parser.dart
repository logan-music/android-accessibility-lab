import 'dart:convert';

class ParseResult {
  final Command? command;
  final String? error;
  ParseResult.ok(this.command) : error = null;
  ParseResult.err(this.error) : command = null;

  bool get isOk => command != null;
}

enum CommandAction {
  clickText,
  clickResourceId,
  openApp,
  setText,
  globalAction,
  scroll,
  wait,
  tapCoords,
  raw,
}

extension CommandActionExt on CommandAction {
  /// canonical action name expected by native layer
  String get name {
    switch (this) {
      case CommandAction.clickText:
        return 'click';
      case CommandAction.clickResourceId:
        return 'click_id';
      case CommandAction.openApp:
        return 'open';
      case CommandAction.setText:
        return 'type';
      case CommandAction.globalAction:
        return 'global';
      case CommandAction.scroll:
        return 'scroll';
      case CommandAction.wait:
        return 'wait';
      case CommandAction.tapCoords:
        return 'tap';
      case CommandAction.raw:
        return 'raw';
    }
  }

  /// accepts a bunch of aliases and maps to internal enum
  static CommandAction? fromString(String s) {
    final v = s.toLowerCase().trim();
    switch (v) {
      case 'click':
      case '/click':
      case 'click_text':
      case 'clicktext':
        return CommandAction.clickText;
      case 'click_id':
      case 'clickid':
      case '/clickid':
      case 'click_by_id':
      case 'click_by_resource':
      case 'clickresourceid':
        return CommandAction.clickResourceId;
      case 'open':
      case 'start':
      case '/open':
      case 'select':
      case '/select':
      case 'open_app':
      case 'launch':
        return CommandAction.openApp;
      case 'type':
      case '/type':
      case 'set_text':
      case 'settext':
        return CommandAction.setText;
      case 'global':
      case 'global_action':
      case 'action':
        return CommandAction.globalAction;
      case 'scroll':
      case '/swipe':
      case 'swipe':
        return CommandAction.scroll;
      case 'wait':
      case 'sleep':
      case 'delay':
        return CommandAction.wait;
      case 'tap':
      case 'tap_coords':
      case 'tapcoords':
      case 'tap_xy':
        return CommandAction.tapCoords;
      case 'raw':
      default:
        return CommandAction.raw;
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
  /// Matches expected keys in native code: id, device_id, action, payload, created_at
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
  static const int _maxTextLength = 256; // for click_text, set_text etc.
  static const int _maxPayloadKeys = 20;
  static const int _maxIdLength = 128;
  static const double _maxCoord = 10000; // sanity for coords
  static final SimpleRateLimiter _rateLimiter = SimpleRateLimiter(maxCalls: 8, windowSeconds: 30);

  /// Parse a raw DB row (Map) coming from SupabaseListener._handleCommand
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
          // if derived payload present, merge later
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
            // If it's plain string, wrap as { "value": "<string>" } for legacy
            payload = {'value': payloadRaw};
          }
        } else if (payloadRaw is Map) {
          payload = Map<String, dynamic>.from(payloadRaw);
        } else {
          payload = {'value': payloadRaw};
        }
      }

      // If action derived from legacy command text includes additional payload, merge
      if ((raw['command'] ?? raw['cmd']) != null) {
        final derived = _deriveActionFromCommandText((raw['command'] ?? raw['cmd']).toString());
        if (derived['payload'] is Map) {
          // merge but don't overwrite existing keys
          (derived['payload'] as Map).forEach((k, v) {
            payload.putIfAbsent(k, () => v);
          });
        }
      }

      // Basic payload size check
      if (payload.length > _maxPayloadKeys) return ParseResult.err('payload too large');

      // Action-specific validation and sanitization
      switch (actionEnum) {
        case CommandAction.clickText:
          return _parseClickText(id, deviceId, payload, createdAtRaw);
        case CommandAction.clickResourceId:
          return _parseClickId(id, deviceId, payload, createdAtRaw);
        case CommandAction.openApp:
          return _parseOpenApp(id, deviceId, payload, createdAtRaw);
        case CommandAction.setText:
          return _parseSetText(id, deviceId, payload, createdAtRaw);
        case CommandAction.globalAction:
          return _parseGlobalAction(id, deviceId, payload, createdAtRaw);
        case CommandAction.scroll:
          return _parseScroll(id, deviceId, payload, createdAtRaw);
        case CommandAction.wait:
          return _parseWait(id, deviceId, payload, createdAtRaw);
        case CommandAction.tapCoords:
          return _parseTapCoords(id, deviceId, payload, createdAtRaw);
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

  static ParseResult _parseClickText(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final text = _extractString(payload, ['text', 'value', 'query']);
    if (text == null || text.trim().isEmpty) return ParseResult.err('click requires non-empty text');
    if (text.length > _maxTextLength) return ParseResult.err('text too long');
    final sanitized = _sanitizeText(text);
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.clickText,
      payload: {'text': sanitized},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseClickId(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final rid = _extractString(payload, ['resource_id', 'id', 'rid', 'view_id']);
    if (rid == null || rid.trim().isEmpty) return ParseResult.err('click_id requires resource_id/view_id');
    if (rid.length > 240) return ParseResult.err('resource_id too long');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.clickResourceId,
      payload: {'resource_id': rid.trim()},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseOpenApp(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final pkg = _extractString(payload, ['package', 'pkg', 'app']);
    if (pkg == null || pkg.trim().isEmpty) return ParseResult.err('open_app requires package name');
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(pkg)) return ParseResult.err('invalid package name');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.openApp,
      payload: {'package': pkg.trim()},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseSetText(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final text = _extractString(payload, ['text', 'value']);
    if (text == null) return ParseResult.err('set_text requires text');
    if (text.length > _maxTextLength) return ParseResult.err('text too long');
    final target = _extractString(payload, ['target_text', 'target', 'resource_id', 'view_id']);
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.setText,
      payload: {
        'text': _sanitizeText(text),
        if (target != null) 'target': target.trim(),
      },
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseGlobalAction(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final act = _extractString(payload, ['name', 'action', 'global']);
    if (act == null) return ParseResult.err('global_action requires name');
    final nameLower = act.toLowerCase().trim();
    // whitelist allowed global actions
    const allowed = {'back', 'home', 'recents', 'notifications', 'quick_settings'};
    if (!allowed.contains(nameLower)) return ParseResult.err('unsupported global_action');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.globalAction,
      payload: {'name': nameLower},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseScroll(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final dir = _extractString(payload, ['direction', 'dir'])?.toLowerCase();
    final amtRaw = payload['amount'] ?? payload['amt'] ?? payload['count'];
    final amount = amtRaw is int ? amtRaw : (int.tryParse('$amtRaw') ?? 1);

    if (dir == null || !(dir == 'up' || dir == 'down' || dir == 'left' || dir == 'right')) {
      return ParseResult.err('scroll requires direction (up/down/left/right)');
    }
    if (amount <= 0 || amount > 50) return ParseResult.err('scroll amount out of range');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.scroll,
      payload: {'direction': dir, 'amount': amount},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseWait(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final msRaw = payload['ms'] ?? payload['millis'] ?? payload['milliseconds'] ?? payload['duration'];
    final ms = msRaw is int ? msRaw : (int.tryParse('$msRaw') ?? 0);
    if (ms <= 0 || ms > 120000) return ParseResult.err('wait duration invalid (0 < ms <= 120000)');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.wait,
      payload: {'ms': ms},
      createdAt: createdAt,
    );
    return ParseResult.ok(cmd);
  }

  static ParseResult _parseTapCoords(String id, String deviceId, Map<String, dynamic> payload, dynamic createdAtRaw) {
    final xRaw = payload['x'];
    final yRaw = payload['y'];
    final x = xRaw is num ? xRaw.toDouble() : double.tryParse('$xRaw');
    final y = yRaw is num ? yRaw.toDouble() : double.tryParse('$yRaw');

    if (x == null || y == null) return ParseResult.err('tap_coords requires numeric x and y');
    if (x.abs() > _maxCoord || y.abs() > _maxCoord) return ParseResult.err('coords out of bounds');
    final createdAt = _parseDate(createdAtRaw);
    final cmd = Command(
      id: id,
      deviceId: deviceId,
      action: CommandAction.tapCoords,
      payload: {'x': x, 'y': y},
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
        // try to stringify
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

  static String _sanitizeText(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Try a simple heuristic to derive action + payload from a legacy command string
  /// e.g. "/click OK" -> { action: 'click', payload: { text: 'OK' } }
  static Map<String, dynamic> _deriveActionFromCommandText(String cmdText) {
    final raw = cmdText.trim();
    if (raw.isEmpty) return {'action': 'raw', 'payload': {}};

    final parts = raw.split(RegExp(r'\s+'));
    var first = parts[0];
    if (first.startsWith('/')) first = first.substring(1);
    final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    switch (first.toLowerCase()) {
      case 'click':
        return {'action': 'click', 'payload': {'text': args}};
      case 'select':
      case 'open':
      case 'start':
        return {'action': 'open', 'payload': {'package': args}};
      case 'clickid':
      case 'click_id':
      case 'clickbyid':
        return {'action': 'click_id', 'payload': {'resource_id': args}};
      case 'type':
        return {'action': 'type', 'payload': {'text': args}};
      case 'back':
        return {'action': 'global', 'payload': {'name': 'back'}};
      case 'home':
        return {'action': 'global', 'payload': {'name': 'home'}};
      case 'swipe':
        return {'action': 'scroll', 'payload': {'direction': args.split(' ').firstWhere((_) => true, orElse: () => 'left')}};
      default:
        return {'action': 'raw', 'payload': {'text': raw}};
    }
  }
}
