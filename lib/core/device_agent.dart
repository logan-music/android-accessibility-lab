// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// - Native command execution is done via MethodChannel "cyber_accessibility_agent/commands"
class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // Config (set via configure)
  late final String supabaseUrl;
  late final String anonKey;
  Uri? registerUri;

  String? deviceId;
  String? deviceJwt;

  // Polling
  Duration pollInterval = const Duration(seconds: 5);
  Timer? _pollTimer;
  final http.Client _http = http.Client();

  bool _running = false;

  // Native method channel to dispatch commands to platform (MainActivity / AgentService)
  static const MethodChannel _native = MethodChannel('cyber_accessibility_agent/commands');

  /// Configure DeviceAgent. Should be called before start().
  /// Optional: pass deviceId/deviceJwt if known; otherwise will load from prefs.
  Future<void> configure({
    required String supabaseUrl,
    required String anonKey,
    String? deviceId,
    String? deviceJwt,
    Duration? pollInterval,
    Uri? registerUri,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.anonKey = anonKey;
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    if (pollInterval != null) this.pollInterval = pollInterval;
    this.registerUri = registerUri;

    final prefs = await SharedPreferences.getInstance();
    this.deviceId ??= prefs.getString('device_id');
    this.deviceJwt ??= prefs.getString('device_jwt');

    print('[DeviceAgent] configured deviceId=${this.deviceId != null ? "present" : "null"}, deviceJwt=${this.deviceJwt != null ? "present" : "null"}');
  }

  /// Persist credentials locally (SharedPreferences).
  Future<void> persistCredentials({required String deviceId, required String deviceJwt}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    await prefs.setString('device_jwt', deviceJwt);
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    print('[DeviceAgent] persisted credentials for device=$deviceId');
  }

  /// Start polling loop. If deviceJwt missing and registerUri is provided, attempt auto-register.
  Future<void> start() async {
    if (_running) return;

    // ensure deviceId loaded
    if (deviceId == null) {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('device_id');
    }

    // If no deviceJwt but registerUri available, try to register
    if (deviceJwt == null && registerUri != null && deviceId != null) {
      print('[DeviceAgent] no deviceJwt; attempting auto-register via registerUri');
      try {
        final reg = await registerDeviceViaEdge(
          registerUri: registerUri!,
          requestedId: deviceId!,
          displayName: 'Device ${deviceId!.substring(0, deviceId!.length > 8 ? 8 : deviceId!.length)}',
          consent: true,
          metadata: {'auto_registered': true},
        );
        if (reg != null) {
          print('[DeviceAgent] auto-register populated credentials (maybe)');
        } else {
          print('[DeviceAgent] auto-register returned null');
        }
      } catch (e) {
        print('[DeviceAgent] auto-register exception: $e');
      }
    }

    if (deviceId == null) {
      // generate a local id if still missing (should normally be created by UI)
      final generated = DateTime.now().millisecondsSinceEpoch.toString();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('device_id', generated);
      deviceId = generated;
      print('[DeviceAgent] generated fallback device id: $generated');
    }

    _running = true;
    // immediate poll then periodic
    await _pollOnce();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    print('[DeviceAgent] started for device=$deviceId');
  }

  /// Stop polling
  Future<void> stop() async {
    _pollTimer?.cancel();
    _running = false;
    print('[DeviceAgent] stopped');
  }

  /// Single poll iteration: fetch pending commands and handle them.
  Future<void> _pollOnce() async {
    if (deviceId == null) return;

    try {
      // fetch commands targeted to this device and pending
      final encoded = Uri.encodeComponent(deviceId!);
      final uri = Uri.parse('$supabaseUrl/rest/v1/device_commands?device_id=eq.$encoded&status=eq.pending&order=created_at.asc&limit=5');

      final res = await _http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer ${deviceJwt ?? anonKey}',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 12));

      if (res.statusCode == 401) {
        print('[DeviceAgent] auth error 401 - device token may be invalid');
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
    } on TimeoutException {
      print('[DeviceAgent] poll timeout');
    } catch (e) {
      print('[DeviceAgent] poll error: $e');
    }
  }

  Future<void> _handleCommandRow(Map<String, dynamic> row) async {
    String? id;
    try {
      id = row['id']?.toString();
      final action = row['action']?.toString() ?? '';
      final payload = row['payload'];
      final createdAt = row['created_at'];

      if (id == null || action.isEmpty) {
        print('[DeviceAgent] invalid command row: missing id/action');
        await _markFailed(id, 'invalid_row');
        return;
      }

      // Update command to processing
      await _patchCommandRow(id, {
        'status': 'processing',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Build method args expected by native: id, device_id, action, payload, created_at
      final methodArgs = {
        'id': id,
        'device_id': deviceId,
        'action': action,
        'payload': payload ?? {},
        'created_at': createdAt?.toString() ?? DateTime.now().toUtc().toIso8601String(),
      };

      // Call native dispatcher
      Map<String, dynamic> execResult;
      try {
        final res = await _native.invokeMethod('dispatch', methodArgs).timeout(const Duration(seconds: 30));
        if (res is Map) {
          execResult = Map<String, dynamic>.from(res as Map);
        } else {
          execResult = {'success': res == true, 'result': res};
        }
      } catch (e) {
        execResult = {'success': false, 'error': 'native_dispatch_error: $e'};
      }

      final success = (execResult['success'] == true);
      await _markDoneOrFailed(id, success, execResult);
    } catch (e) {
      print('[DeviceAgent] handleCommandRow exception for id=$id : $e');
      try {
        await _markFailed(id, 'exception_handling_command');
      } catch (_) {}
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
    if (deviceJwt == null) {
      print('[DeviceAgent] cannot patch command $id - no deviceJwt');
      return;
    }

    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/device_commands?id=eq.$id');
      final res = await _http.patch(uri,
          headers: {
            'apikey': anonKey,
            'Authorization': 'Bearer $deviceJwt',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal'
          },
          body: jsonEncode(body)).timeout(const Duration(seconds: 12));

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

  /// Send heartbeat / upsert device row (best-effort).
  Future<void> sendHeartbeat() async {
    if (deviceId == null) return;

    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/devices');
      final body = jsonEncode({
        'id': deviceId,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
        'online': true
      });

      final res = await _http.post(uri, headers: {
        'Content-Type': 'application/json',
        'apikey': anonKey,
        'Authorization': 'Bearer ${deviceJwt ?? anonKey}',
        'Prefer': 'resolution=merge-duplicates'
      }, body: body).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        // ok
        // print('[DeviceAgent] heartbeat ok');
      } else {
        print('[DeviceAgent] heartbeat failed ${res.statusCode}: ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] heartbeat timeout');
    } catch (e) {
      print('[DeviceAgent] heartbeat error: $e');
    }
  }

  /// Register device via edge function (recommended). The edge function should return JSON
  /// with at least `device_id` and optionally `token` (device JWT).
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
