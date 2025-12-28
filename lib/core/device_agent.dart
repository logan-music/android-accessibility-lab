// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'command_parser.dart';
import '../platform/accessibility_bridge.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // configure at startup from main or ConsentPage
  late final String supabaseUrl;
  late final String anonKey;
  Uri? registerUri; // optional edge function URI (if provided in configure)

  String? deviceId;
  String? deviceJwt;

  Duration pollInterval = const Duration(seconds: 5);
  Timer? _pollTimer;
  final http.Client _http = http.Client();

  bool _running = false;

  /// Configure DeviceAgent.
  /// Pass optional [registerUri] if you want DeviceAgent.start() to attempt
  /// an automatic registration (and get device JWT) when deviceJwt is missing.
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

    // load from prefs if not provided
    final prefs = await SharedPreferences.getInstance();
    this.deviceId ??= prefs.getString('device_id');
    this.deviceJwt ??= prefs.getString('device_jwt');
    print('[DeviceAgent] configured deviceId=${this.deviceId != null ? "present" : "null"}, deviceJwt=${this.deviceJwt != null ? "present" : "null"}');
  }

  /// Persist device credentials locally
  Future<void> persistCredentials({required String deviceId, required String deviceJwt}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    await prefs.setString('device_jwt', deviceJwt);
    this.deviceId = deviceId;
    this.deviceJwt = deviceJwt;
    print('[DeviceAgent] persisted credentials for device=$deviceId');
  }

  /// Start the poller. If deviceJwt is missing and registerUri was provided
  /// during configure(), an attempt to register and obtain a token will be made.
  Future<void> start() async {
    if (_running) return;

    // If we don't have deviceId, try to load prefs (rare)
    if (deviceId == null) {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('device_id');
    }

    // If no deviceJwt but registerUri available, try to register/get token
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
          print('[DeviceAgent] auto-register populated credentials');
        } else {
          print('[DeviceAgent] auto-register returned null (no token)');
        }
      } catch (e) {
        print('[DeviceAgent] auto-register exception: $e');
      }
    }

    if (deviceId == null || deviceJwt == null) {
      print('[DeviceAgent] missing deviceId or deviceJwt; not starting poller');
      return;
    }

    _running = true;
    // immediate poll then periodic
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
    if (deviceId == null || deviceJwt == null) return;

    try {
      final encodedId = Uri.encodeQueryComponent(deviceId!);
      final uri = Uri.parse(
          '$supabaseUrl/rest/v1/device_commands?device_id=eq.$encodedId&status=eq.pending&order=created_at.asc&limit=5');

      final res = await _http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $deviceJwt',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode == 401) {
        print('[DeviceAgent] auth error 401 - device token may be invalid');
        // don't hammer; client of this class can decide to refresh token manually
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
      await _markDoneOrFailed(id, success, res);
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
      // PostgREST expects JSON body for PATCH/UPDATE
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

  /// Optional helper: explicit register via register-device edge function
  /// (useful to obtain device token if not present).
  ///
  /// NOTE: This function expects the edge function to return a JSON object
  /// that contains at least `device_id` and optionally `token` (device JWT).
  /// If `token` is present it will be persisted locally.
  Future<Map<String, dynamic>?> registerDeviceViaEdge({
    required Uri registerUri,
    required String requestedId,
    String? displayName,
    bool consent = true,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final payload = {
        // many edge functions use 'requestedId' or 'device_id' - include both to be safe
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
            // edge function may require anon/other headers; avoid including service_role here
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
            // persist id only; token absent (edge may just create row)
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