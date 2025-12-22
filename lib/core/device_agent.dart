// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'command_parser.dart';
import '../platform/accessibility_bridge.dart';

class DeviceAgent {
  DeviceAgent._();

  static final DeviceAgent instance = DeviceAgent._();

  // configure at startup from main or ConsentPage
  late final String supabaseUrl;
  late final String anonKey;
  String? deviceId;
  String? deviceJwt;

  Duration pollInterval = const Duration(seconds: 5);
  Timer? _pollTimer;
  final http.Client _http = http.Client();

  bool _running = false;

  // init with required config
  Future<void> configure({
    required String supabaseUrl,
    required String anonKey,
    String? deviceId,
    String? deviceJwt,
    Duration? pollInterval,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.anonKey = anonKey;
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    if (pollInterval != null) this.pollInterval = pollInterval;

    // load from prefs if not provided
    final prefs = await SharedPreferences.getInstance();
    this.deviceId ??= prefs.getString('device_id');
    this.deviceJwt ??= prefs.getString('device_jwt');
  }

  Future<void> persistCredentials({required String deviceId, required String deviceJwt}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    await prefs.setString('device_jwt', deviceJwt);
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
  }

  Future<void> start() async {
    if (_running) return;
    if (deviceId == null || deviceJwt == null) {
      print('[DeviceAgent] missing deviceId or deviceJwt; not starting poller');
      return;
    }
    _running = true;
    // start immediate then periodic
    await _pollOnce();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    print('[DeviceAgent] started for device=$deviceId');
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _running = false;
    print('[DeviceAgent] stopped');
  }

  Future<void> _pollOnce() async {
    try {
      if (deviceId == null || deviceJwt == null) return;

      final uri = Uri.parse(
          '$supabaseUrl/rest/v1/device_commands?device_id=eq.${Uri.encodeComponent(deviceId!)}&status=eq.pending&order=created_at.asc&limit=5');

      final res = await _http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $deviceJwt',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode == 401) {
        print('[DeviceAgent] auth error 401 - token may be invalid');
        return;
      }

      if (res.statusCode != 200) {
        print('[DeviceAgent] fetch pending commands failed: ${res.statusCode} ${res.body}');
        return;
      }

      final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
      if (rows.isEmpty) return;

      for (final r in rows) {
        if (r is! Map<String, dynamic>) continue;
        await _handleCommandRow(r);
      }
    } catch (e) {
      print('[DeviceAgent] poll error: $e');
    }
  }

  Future<void> _handleCommandRow(Map<String, dynamic> row) async {
    try {
      final id = row['id']?.toString();
      final action = row['action']?.toString();
      final payload = row['payload'];
      final createdAt = row['created_at'];

      if (id == null || action == null) {
        print('[DeviceAgent] invalid command row: missing id/action');
        await _markFailed(id, 'invalid_row');
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
      // Execute via AccessibilityBridge (serializes native calls)
      final res = await AccessibilityBridge().executeCommand(cmd, timeout: const Duration(seconds: 20), maxRetries: 2);

      final success = res['success'] == true;

      // update command status
      await _markDoneOrFailed(id, success, res);
    } catch (e) {
      print('[DeviceAgent] handleCommandRow exception: $e');
    }
  }

  Future<void> _markDoneOrFailed(String id, bool success, Map<String, dynamic> result) async {
    final status = success ? 'done' : 'failed';
    await _patchCommandRow(id, {
      'status': status,
      'result': result,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _markFailed(String? id, String reason) async {
    if (id == null) return;
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
            'Authorization': 'Bearer $deviceJwt',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body)).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400) {
        print('[DeviceAgent] failed to patch command $id: ${res.statusCode} ${res.body}');
      } else {
        print('[DeviceAgent] patched command $id -> ${body['status']}');
      }
    } catch (e) {
      print('[DeviceAgent] patch error: $e');
    }
  }

  // Optional helper: explicit register via register-device edge function
  // (useful to obtain device token if not present)
  Future<Map<String, dynamic>?> registerDeviceViaEdge({
    required Uri registerUri,
    required String requestedId,
    String? displayName,
    bool consent = true,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final payload = {
        'device_id': requestedId,
        'display_name': displayName,
        'consent': consent,
        'metadata': metadata
      };
      final res = await _http.post(registerUri,
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        // save device credentials locally
        final tok = j['token'] as String?;
        final did = j['device_id'] as String?;
        if (tok != null && did != null) {
          await persistCredentials(deviceId: did, deviceJwt: tok);
        }
        return j;
      } else {
        print('[DeviceAgent] register failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      print('[DeviceAgent] register exception: $e');
    }
    return null;
  }
}
