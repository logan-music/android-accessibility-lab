import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'command_parser.dart';
import '../platform/command_dispatcher.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // Configuration (must call configure() early, e.g. in main)
  late final String supabaseUrl;
  late final String anonKey;
  Uri? registerUri;

  String? deviceId;
  String? deviceJwt;

  Duration pollInterval = const Duration(seconds: 5);
  Timer? _pollTimer;
  final http.Client _http = http.Client();

  bool _running = false;
  bool _busy = false;

  /// Configure DeviceAgent. Loads persisted device_id / device_jwt if not
  /// supplied.
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

  /// Persist device credentials locally
  Future<void> persistCredentials({
    required String deviceId,
    required String deviceJwt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    await prefs.setString('device_jwt', deviceJwt);
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    print('[DeviceAgent] persisted credentials for device=$deviceId');
  }

  // ------------------------------------------------------------
  // Start / Stop
  // ------------------------------------------------------------

  /// Start polling for commands.
  /// Poller will only start if both deviceId and deviceJwt are present.
  /// This version DOES NOT auto-register nor attempt re-register on 401.
  Future<void> start() async {
    if (_running) return;

    // Try load persisted id/token if not already set
    if (deviceId == null || deviceJwt == null) {
      final prefs = await SharedPreferences.getInstance();
      deviceId ??= prefs.getString('device_id');
      deviceJwt ??= prefs.getString('device_jwt');
    }

    if (deviceId == null || deviceJwt == null) {
      print('[DeviceAgent] missing deviceId or deviceJwt; not starting poller');
      return;
    }

    _running = true;
    await _pollOnce(); // immediate
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    print('[DeviceAgent] started for device=$deviceId');
  }

  /// Stop polling
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _busy = false;
    print('[DeviceAgent] stopped');
  }

  // ------------------------------------------------------------
  // Polling & Command Handling
  // ------------------------------------------------------------

  Future<void> _pollOnce() async {
    if (!_running) return;
    if (deviceId == null || deviceJwt == null) return;
    if (_busy) return;

    _busy = true;
    try {
      final encodedId = Uri.encodeComponent(deviceId!);
      final uri = Uri.parse(
          '$supabaseUrl/rest/v1/device_commands?device_id=eq.$encodedId&status=eq.pending&order=created_at.asc&limit=5');

      final res = await _http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $deviceJwt',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode == 401) {
        // Token invalid — log and stop attempting auto-fixes here.
        print('[DeviceAgent] auth error 401 - device token invalid or expired. Poller will wait for manual refresh.');
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
    } catch (e, st) {
      print('[DeviceAgent] poll error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleCommandRow(Map<String, dynamic> row) async {
    String? id;
    try {
      id = row['id']?.toString();
      final action = row['action']?.toString();
      final payload = row['payload'];
      final createdAt = row['created_at'];

      if (id == null) {
        print('[DeviceAgent] invalid command row: missing id');
        return;
      }

      final raw = {
        'id': id,
        'device_id': deviceId,
        'action': action,
        'payload': payload,
        'created_at': createdAt,
        'command': row['command'] ?? row['cmd'],
      };

      final parsed = CommandParser.parse(raw, deviceId ?? '');
      if (parsed.error != null) {
        print('[DeviceAgent] parse error for cmd $id: ${parsed.error}');
        await _markFailed(id, 'parse_error:${parsed.error}');
        return;
      }

      final cmd = parsed.command!;
      await _markRunning(id);

      // Execute command via platform dispatcher
      Map<String, dynamic> res;
      try {
        res = await CommandDispatcher.instance.executeCommand(cmd, timeout: const Duration(seconds: 60), maxRetries: 2);
      } catch (e) {
        print('[DeviceAgent] command execution exception for $id: $e');
        await _markFailed(id, 'execution_exception');
        return;
      }

      final success = res['success'] == true;
      await _markDoneOrFailed(id, success, res);
    } catch (e, st) {
      print('[DeviceAgent] handleCommandRow exception for id=$id : $e\n$st');
      try {
        await _markFailed(id, 'exception_handling_command');
      } catch (_) {}
    }
  }

  Future<void> _markRunning(String id) async {
    if (deviceJwt == null) return;
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/device_commands?id=eq.$id');
      final body = {'status': 'running', 'updated_at': DateTime.now().toUtc().toIso8601String()};
      final res = await _http.patch(uri,
          headers: {
            'apikey': anonKey,
            'Authorization': 'Bearer $deviceJwt',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal'
          },
          body: jsonEncode(body)).timeout(const Duration(seconds: 8));

      if (res.statusCode >= 400) {
        print('[DeviceAgent] markRunning failed for $id: ${res.statusCode} ${res.body}');
      } else {
        print('[DeviceAgent] marked running $id');
      }
    } catch (e) {
      print('[DeviceAgent] markRunning error: $e');
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

  // ------------------------------------------------------------
  // Registration helper (manual use only)
  // ------------------------------------------------------------

  /// Register device via register-device edge function (recommended).
  /// This method will persist token if the edge function returns one.
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

  // ------------------------------------------------------------
  // Heartbeat
  // ------------------------------------------------------------
  Future<void> sendHeartbeat() async {
    if (deviceId == null) return;

    try {
      final authToken = deviceJwt ?? anonKey;
      final uri = Uri.parse('$supabaseUrl/rest/v1/devices');
      final body = jsonEncode({
        'id': deviceId,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
        'online': true
      });

      final res = await _http.post(uri, headers: {
        'Content-Type': 'application/json',
        'apikey': anonKey,
        'Authorization': 'Bearer $authToken',
        'Prefer': 'resolution=merge-duplicates'
      }, body: body).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        // success
      } else {
        print('[DeviceAgent] heartbeat failed ${res.statusCode}: ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] heartbeat timeout');
    } catch (e) {
      print('[DeviceAgent] heartbeat error: $e');
    }
  }
}