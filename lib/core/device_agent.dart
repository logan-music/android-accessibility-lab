// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'command_parser.dart';
import '../platform/command_dispatcher.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  late final String supabaseUrl;
  late final String anonKey;

  String? deviceId;

  Duration pollInterval = const Duration(seconds: 5);
  Timer? _pollTimer;
  final http.Client _http = http.Client();

  bool _running = false;
  bool _busy = false;

  // ---------------------------------------------------------------------------
  // Configure
  // ---------------------------------------------------------------------------
  Future<void> configure({
    required String supabaseUrl,
    required String anonKey,
    String? deviceId,
    Duration? pollInterval,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.anonKey = anonKey;
    this.deviceId = deviceId;
    if (pollInterval != null) this.pollInterval = pollInterval;

    final prefs = await SharedPreferences.getInstance();
    this.deviceId ??= prefs.getString('device_id');

    print('[DeviceAgent] configured deviceId=${this.deviceId}');
  }

  // ---------------------------------------------------------------------------
  // Persist device id only (NO JWT)
  // ---------------------------------------------------------------------------
  Future<void> persistDeviceId(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);
    this.deviceId = deviceId;
    print('[DeviceAgent] persisted deviceId=$deviceId');
  }

  // ---------------------------------------------------------------------------
  // Start / Stop poller
  // ---------------------------------------------------------------------------
  Future<void> start() async {
    if (_running) return;

    if (deviceId == null) {
      final prefs = await SharedPreferences.getInstance();
      deviceId ??= prefs.getString('device_id');
    }

    if (deviceId == null) {
      print('[DeviceAgent] missing deviceId; poller not started');
      return;
    }

    _running = true;
    await _pollOnce(); // immediate poll
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());

    print('[DeviceAgent] started for device=$deviceId');
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _busy = false;
    print('[DeviceAgent] stopped');
  }

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------
  Future<void> _pollOnce() async {
    if (!_running || _busy || deviceId == null) return;

    _busy = true;
    try {
      final encodedId = Uri.encodeComponent(deviceId!);
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/device_commands'
        '?device_id=eq.$encodedId'
        '&status=eq.pending'
        '&order=created_at.asc'
        '&limit=5',
      );

      final res = await _http
          .get(uri, headers: {
            'apikey': anonKey,
            'Authorization': 'Bearer $anonKey',
            'Accept': 'application/json',
          })
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        print('[DeviceAgent] poll failed: ${res.statusCode} ${res.body}');
        return;
      }

      final List<dynamic> rows = jsonDecode(res.body);
      if (rows.isEmpty) return;

      for (final r in rows) {
        if (r is Map<String, dynamic>) {
          await _handleCommandRow(r);
        }
      }
    } on TimeoutException {
      print('[DeviceAgent] poll timeout');
    } catch (e, st) {
      print('[DeviceAgent] poll error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Handle command
  // ---------------------------------------------------------------------------
  Future<void> _handleCommandRow(Map<String, dynamic> row) async {
    String? id;
    try {
      id = row['id']?.toString();
      if (id == null) return;

      final raw = {
        'id': id,
        'device_id': deviceId,
        'action': row['action'],
        'payload': row['payload'],
        'created_at': row['created_at'],
        'command': row['command'] ?? row['cmd'],
      };

      final parsed = CommandParser.parse(raw, deviceId ?? '');
      if (parsed.error != null) {
        await _markFailed(id, 'parse_error:${parsed.error}');
        return;
      }

      await _markRunning(id);

      Map<String, dynamic> result;
      try {
        result = await CommandDispatcher.instance.executeCommand(
          parsed.command!,
          timeout: const Duration(seconds: 60),
          maxRetries: 2,
        );
      } catch (e) {
        await _markFailed(id, 'execution_exception');
        return;
      }

      final success = result['success'] == true;
      await _markDoneOrFailed(id, success, result);
    } catch (e, st) {
      print('[DeviceAgent] handle error id=$id $e\n$st');
      if (id != null) {
        await _markFailed(id, 'handler_exception');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Command status helpers
  // ---------------------------------------------------------------------------
  Future<void> _markRunning(String id) async {
    await _patchCommandRow(id, {
      'status': 'in_progress',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _markDoneOrFailed(
    String id,
    bool success,
    Map<String, dynamic> result,
  ) async {
    await _patchCommandRow(id, {
      'status': success ? 'done' : 'failed',
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

  Future<void> _patchCommandRow(
    String id,
    Map<String, dynamic> body,
  ) async {
    try {
      final uri =
          Uri.parse('$supabaseUrl/rest/v1/device_commands?id=eq.$id');

      final res = await _http
          .patch(
            uri,
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $anonKey',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400) {
        print(
            '[DeviceAgent] patch failed $id: ${res.statusCode} ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] patch timeout id=$id');
    } catch (e) {
      print('[DeviceAgent] patch error id=$id $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat (upsert device)
  // ---------------------------------------------------------------------------
  Future<void> sendHeartbeat() async {
    if (deviceId == null) return;

    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/devices');
      final body = jsonEncode({
        'id': deviceId,
        'online': true,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      });

      final res = await _http
          .post(
            uri,
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $anonKey',
              'Content-Type': 'application/json',
              'Prefer': 'resolution=merge-duplicates',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400) {
        print(
            '[DeviceAgent] heartbeat failed ${res.statusCode}: ${res.body}');
      }
    } on TimeoutException {
      print('[DeviceAgent] heartbeat timeout');
    } catch (e) {
      print('[DeviceAgent] heartbeat error $e');
    }
  }
}