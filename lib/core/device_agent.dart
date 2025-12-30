// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'command_parser.dart';
import '../platform/accessibility_bridge.dart';

/// DeviceAgent
///
/// - Polls `device_commands` for pending commands for this device_id.
/// - Executes commands via AccessibilityBridge (native accessibility service).
/// - Uses anonKey for queries/patches (no service_role inside APK).
/// - Heartbeat: upserts `devices` table with { id, online, last_seen } periodically.
/// - Optionally registerDeviceViaEdge() if you want the server to issue a device_jwt.
class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // configured at startup
  late final String supabaseUrl;
  late final String anonKey;

  String? deviceId;
  String? deviceJwt; // optional, may be null

  // Polling interval for pending commands
  Duration pollInterval = const Duration(seconds: 5);
  // Heartbeat interval for devices.last_seen / online
  Duration heartbeatInterval = const Duration(seconds: 30);

  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  final http.Client _http = http.Client();

  bool _running = false;
  bool _accessibilityEnabled = false;

  // ----------------------------
  // CONFIG
  // ----------------------------
  Future<void> configure({
    required String supabaseUrl,
    required String anonKey,
    String? deviceId,
    String? deviceJwt,
    Duration? pollInterval,
    Duration? heartbeatInterval,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.anonKey = anonKey;
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    if (pollInterval != null) this.pollInterval = pollInterval;
    if (heartbeatInterval != null) this.heartbeatInterval = heartbeatInterval;

    // load device id/jwt from prefs if not provided
    final prefs = await SharedPreferences.getInstance();
    this.deviceId ??= prefs.getString('device_id');
    this.deviceJwt ??= prefs.getString('device_jwt');

    print('[DeviceAgent] configured deviceId=${this.deviceId != null ? "present" : "null"}, deviceJwt=${this.deviceJwt != null ? "present" : "null"}');
  }

  /// Persist device credentials locally (device_jwt optional)
  Future<void> persistCredentials({required String deviceId, String? deviceJwt}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    if (deviceJwt != null) await prefs.setString('device_jwt', deviceJwt);
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt ?? this.deviceJwt;
    print('[DeviceAgent] persisted credentials for device=$deviceId (jwt ${deviceJwt != null ? "saved" : "unchanged"})');
  }

  // ----------------------------
  // ACCESSIBILITY SIGNAL
  // ----------------------------
  /// Called by UI/native when accessibility service is connected/available.
  /// Passing true will attempt to start poller (if not running) and trigger immediate poll.
  Future<void> setAccessibilityEnabled(bool enabled) async {
    _accessibilityEnabled = enabled;
    if (enabled) {
      if (!_running) {
        await start();
      } else {
        // immediate poll so pending commands are picked up now that accessibility is available
        await _pollOnce();
      }
    } else {
      print('[DeviceAgent] accessibility disabled');
      // keep heartbeat running so server knows it's offline if needed
    }
  }

  // ----------------------------
  // START / STOP
  // ----------------------------
  Future<void> start() async {
    if (_running) return;

    // Ensure we have a deviceId (try prefs)
    if (deviceId == null) {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('device_id');
    }

    if (deviceId == null) {
      print('[DeviceAgent] cannot start: deviceId missing');
      return;
    }

    _running = true;

    // immediate actions
    await _upsertHeartbeat(); // mark online immediately
    await _pollOnce();

    // periodic timers
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _upsertHeartbeat());

    print('[DeviceAgent] started for device=$deviceId (poll=${pollInterval.inSeconds}s, heartbeat=${heartbeatInterval.inSeconds}s)');
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _running = false;
    print('[DeviceAgent] stopped');
  }

  // ----------------------------
  // HEARTBEAT / PRESENCE
  // ----------------------------
  Future<void> _upsertHeartbeat() async {
    if (deviceId == null) return;
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/devices');
      final body = jsonEncode({
        'id': deviceId,
        'online': true,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      });

      final res = await _http.post(uri, headers: {
        'Content-Type': 'application/json',
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
        'Prefer': 'return=representation, resolution=merge-duplicates'
      }, body: body).timeout(const Duration(seconds: 8));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        // success
        // optionally parse response or log
        // debug print small message
        // print('[DeviceAgent] heartbeat ok for $deviceId');
      } else {
        print('[DeviceAgent] heartbeat failed ${res.statusCode}: ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] heartbeat timeout');
    } catch (e) {
      print('[DeviceAgent] heartbeat error: $e');
    }
  }

  // ----------------------------
  // POLLING
  // ----------------------------
  Future<void> _pollOnce() async {
    if (!_running || deviceId == null) return;

    try {
      final encodedId = Uri.encodeQueryComponent(deviceId!);
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/device_commands'
        '?device_id=eq.$encodedId'
        '&status=eq.pending'
        '&order=created_at.asc'
        '&limit=5',
      );

      final res = await _http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        // 401 might indicate token mismatch if you used deviceJwt earlier
        print('[DeviceAgent] poll failed ${res.statusCode}: ${res.body}');
        return;
      }

      final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
      if (rows.isEmpty) return;

      for (final r in rows) {
        if (r is! Map<String, dynamic>) continue;
        await _handleCommandRow(r);
      }
    } on TimeoutException {
      print('[DeviceAgent] poll timeout');
    } catch (e) {
      print('[DeviceAgent] poll error: $e');
    }
  }

  // ----------------------------
  // COMMAND HANDLING
  // ----------------------------
  Future<void> _handleCommandRow(Map<String, dynamic> row) async {
    String? id;
    try {
      id = row['id']?.toString();
      final action = row['action']?.toString();
      final payload = row['payload'];
      final createdAt = row['created_at'];

      if (id == null || action == null) {
        print('[DeviceAgent] invalid command row: missing id/action');
        if (id != null) await _markFailed(id, 'invalid_row');
        return;
      }

      // Reconstruct raw row for CommandParser compatibility
      final raw = {
        'id': id,
        'device_id': deviceId,
        'action': action,
        'payload': payload,
        'created_at': createdAt,
      };

      final parsed = CommandParser.parse(raw, deviceId ?? '');
      if (parsed.error != null) {
        print('[DeviceAgent] parse error for cmd $id: ${parsed.error}');
        await _markFailed(id, 'parse_error:${parsed.error}');
        return;
      }

      final cmd = parsed.command!;
      // Execute via AccessibilityBridge (serializes native calls and handles retries)
      final res = await AccessibilityBridge().executeCommand(
        cmd,
        timeout: const Duration(seconds: 20),
        maxRetries: 2,
      );

      final success = res['success'] == true;
      await _markDoneOrFailed(id, success, res);
    } catch (e) {
      print('[DeviceAgent] handleCommandRow exception for id=$id : $e');
      try {
        if (id != null) await _markFailed(id, 'exception_handling_command');
      } catch (_) {}
    }
  }

  // ----------------------------
  // UPDATE COMMAND STATUS
  // ----------------------------
  Future<void> _markDoneOrFailed(String id, bool success, Map<String, dynamic> result) async {
    final status = success ? 'done' : 'failed';
    await _patchCommandRow(id, {
      'status': status,
      'result': result,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _markFailed(String id, String reason) async {
    await _patchCommandRow(id, {
      'status': 'failed',
      'result': {'error': reason},
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _patchCommandRow(String id, Map<String, dynamic> body) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/device_commands?id=eq.$id');

      final res = await _http.patch(uri,
          headers: {
            'apikey': anonKey,
            'Authorization': 'Bearer $anonKey',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal'
          },
          body: jsonEncode(body)).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400) {
        print('[DeviceAgent] failed to patch command $id: ${res.statusCode} ${res.body}');
      } else {
        print('[DeviceAgent] patched command $id -> ${body['status']}');
      }
    } on TimeoutException {
      print('[DeviceAgent] patch timeout for command $id');
    } catch (e) {
      print('[DeviceAgent] patch error: $e');
    }
  }

  // ----------------------------
  // Optional: register via edge function (server-side)
  // ----------------------------
  /// If your server-side edge function returns a device token (device_jwt),
  /// this will persist it locally so you can use it later.
  Future<Map<String, dynamic>?> registerDeviceViaEdge({
    required Uri registerUri,
    required String requestedId,
    String? displayName,
    bool consent = true,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final payload = {
        'requestedId': requestedId,
        'device_id': requestedId,
        'display_name': displayName,
        'consent': consent,
        'metadata': metadata ?? {}
      };

      final res = await _http.post(registerUri,
          headers: {
            'Content-Type': 'application/json',
            'apikey': anonKey,
            'Authorization': 'Bearer $anonKey',
          },
          body: jsonEncode(payload)).timeout(const Duration(seconds: 12));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final j = jsonDecode(res.body);
        if (j is Map<String, dynamic>) {
          final tok = (j['token'] ?? j['device_jwt'] ?? j['jwt']) as String?;
          final did = (j['device_id'] ?? j['id'] ?? j['deviceId'])?.toString();
          if (did != null && tok != null) {
            await persistCredentials(deviceId: did, deviceJwt: tok);
            print('[DeviceAgent] registerDeviceViaEdge: saved credentials device=$did');
          } else if (did != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('device_id', did);
            deviceId = did;
            print('[DeviceAgent] registerDeviceViaEdge: saved device id only ($did)');
          }
          return Map<String, dynamic>.from(j);
        } else {
          print('[DeviceAgent] registerDeviceViaEdge: unexpected response body');
        }
      } else {
        print('[DeviceAgent] register failed: ${res.statusCode} ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] registerDeviceViaEdge: timeout');
    } catch (e) {
      print('[DeviceAgent] register exception: $e');
    }
    return null;
  }
}