// lib/core/supabase_listener.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Device-side Supabase listener/agent
/// - polls device_commands (fallback to commands)
/// - checks consent
/// - marks in_progress -> done/failed and writes result json
/// - updates devices.online / last_seen heartbeat
class SupabaseListener {
  final String deviceId;
  final Duration pollInterval;
  final int pollLimit;
  final Duration heartbeatInterval;

  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  bool _running = false;

  static const MethodChannel _channel = MethodChannel('accessibility_bridge');

  final SupabaseClient _supabase = Supabase.instance.client;

  // preferred table names
  static const String _preferredTable = 'device_commands';
  static const String _fallbackTable = 'commands';
  String _activeTable = _preferredTable;

  SupabaseListener({
    required this.deviceId,
    this.pollInterval = const Duration(seconds: 3),
    this.pollLimit = 10,
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  Future<void> start() async {
    if (_running) return;
    _running = true;

    await _detectCommandsTable();

    // mark device online immediately (upsert)
    await _setDeviceOnline(true);

    // poll for commands
    _pollOnce(); // initial immediate poll
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());

    // heartbeat / last_seen updates
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _setDeviceHeartbeat());

    print('[SupabaseListener] started for device=$deviceId (table=$_activeTable)');
  }

  Future<void> stop() async {
    if (!_running) return;
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _running = false;

    // mark offline
    await _setDeviceOnline(false);

    print('[SupabaseListener] stopped for device=$deviceId');
  }

  Future<void> _detectCommandsTable() async {
    try {
      final res = await _supabase.from(_preferredTable).select('id').limit(1).execute();
      if (res.error == null) {
        _activeTable = _preferredTable;
        return;
      }
    } catch (e) {
      // ignore
    }
    try {
      final res = await _supabase.from(_fallbackTable).select('id').limit(1).execute();
      if (res.error == null) {
        _activeTable = _fallbackTable;
        return;
      }
    } catch (e) {
      // ignore
    }
    _activeTable = _preferredTable; // fallback: keep preferred
  }

  Future<void> _pollOnce() async {
    if (!_running) return;
    try {
      final pending = await _fetchPendingCommands();
      if (pending.isEmpty) return;
      for (final row in pending) {
        // re-check consent before executing
        final consent = await _deviceConsentAllowed();
        if (!consent) {
          await _markCommandFailed(row, 'no_consent');
          continue;
        }
        await _handleCommand(row);
      }
    } catch (e, st) {
      print('[SupabaseListener] poll error for $deviceId: $e\n$st');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPendingCommands() async {
    try {
      final res = await _supabase
          .from(_activeTable)
          .select()
          .eq('device_id', deviceId)
          .eq('status', 'pending')
          .order('created_at', ascending: true)
          .limit(pollLimit)
          .execute();

      if (res.error != null) {
        print('[SupabaseListener] fetch error: ${res.error!.message}');
        return [];
      }

      final data = res.data as List<dynamic>? ?? [];
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      print('[SupabaseListener] fetch exception: $e');
      return [];
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> row) async {
    final int? id = _extractId(row);
    if (id == null) {
      print('[SupabaseListener] skipping command without id: $row');
      return;
    }

    // parse action + payload (supports structured action/payload or legacy 'command' text)
    final parsed = _parseRowToActionPayload(row);
    final String action = parsed['action'] as String;
    final Map<String, dynamic> payload = Map<String, dynamic>.from(parsed['payload'] as Map);

    await _updateStatusById(id, 'in_progress');

    bool success = false;
    dynamic nativeResult;
    try {
      nativeResult = await _sendToNative(id: id.toString(), action: action, payload: payload);

      if (nativeResult == true) {
        success = true;
      } else if (nativeResult is Map) {
        success = nativeResult['success'] == true;
      } else {
        success = nativeResult == true;
      }
    } catch (e, st) {
      print('[SupabaseListener] native execute error id=$id action=$action: $e\n$st');
      success = false;
      nativeResult = {'error': e.toString()};
    }

    if (success) {
      await _updateStatusById(id, 'done', nativeResult);
    } else {
      await _updateStatusById(id, 'failed', nativeResult);
    }
  }

  int? _extractId(Map<String, dynamic> row) {
    try {
      final v = row['id'];
      if (v is int) return v;
      if (v is String) return int.tryParse(v);
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _parseRowToActionPayload(Map<String, dynamic> row) {
    // If structured action/payload present, use them
    if (row.containsKey('action') && row['action'] != null) {
      final action = row['action'].toString();
      final payloadRaw = row['payload'];
      Map<String, dynamic> payload = {};
      if (payloadRaw != null) {
        try {
          if (payloadRaw is Map) {
            payload = Map<String, dynamic>.from(payloadRaw);
          } else if (payloadRaw is String && payloadRaw.isNotEmpty) {
            payload = jsonDecode(payloadRaw) as Map<String, dynamic>;
          }
        } catch (_) {
          payload = {};
        }
      }
      return {'action': action, 'payload': payload};
    }

    // Fallback: parse legacy 'command' text
    final cmdTextRaw = row['command'] ?? row['cmd'] ?? '';
    final cmdText = (cmdTextRaw ?? '').toString().trim();
    if (cmdText.isEmpty) return {'action': 'noop', 'payload': {}};

    final parts = cmdText.split(RegExp(r'\s+'));
    String first = parts[0];
    if (first.startsWith('/')) first = first.substring(1);
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    switch (first.toLowerCase()) {
      case 'select':
        return {'action': 'select', 'payload': {'target': args.join(' ')}};
      case 'open':
      case 'start':
        return {'action': 'open', 'payload': {'app': args.join(' ')}};
      case 'show':
        return {'action': 'show', 'payload': {'what': args.join(' ')}};
      case 'click':
        return {'action': 'click', 'payload': {'target': args.join(' ')}};
      case 'longclick':
        return {'action': 'longclick', 'payload': {'target': args.join(' ')}};
      case 'swipe':
        return {'action': 'swipe', 'payload': {'direction': args.isNotEmpty ? args[0] : 'left'}};
      case 'type':
        return {'action': 'type', 'payload': {'text': args.join(' ')}};
      case 'back':
        return {'action': 'back', 'payload': {}};
      case 'home':
        return {'action': 'home', 'payload': {}};
      case 'recent':
        return {'action': 'recent', 'payload': {}};
      default:
        return {'action': 'raw', 'payload': {'text': cmdText}};
    }
  }

  Future<dynamic> _sendToNative({
    required String id,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final args = <String, dynamic>{
      'id': id,
      'action': action,
      'payload': payload,
    };

    try {
      // enforce a timeout so native doesn't hang poller forever
      final dynamic res = await _channel.invokeMethod('executeCommand', args).timeout(const Duration(seconds: 15));
      return res;
    } on TimeoutException {
      print('[SupabaseListener] native call timeout id=$id action=$action');
      return {'success': false, 'error': 'native_timeout'};
    } catch (e) {
      print('[SupabaseListener] _sendToNative error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<bool> _deviceConsentAllowed() async {
    try {
      final res = await _supabase.from('devices').select('consent').eq('id', deviceId).single().execute();
      if (res.error != null || res.data == null) return false;
      final row = Map<String, dynamic>.from(res.data);
      final c = row['consent'];
      if (c is bool) return c;
      if (c is String) return c.toLowerCase() == 'true';
      return false;
    } catch (e) {
      print('[SupabaseListener] consent check error: $e');
      return false;
    }
  }

  Future<void> _markCommandFailed(Map<String, dynamic> row, String reason) async {
    final id = _extractId(row);
    if (id == null) return;
    await _updateStatusById(id, 'failed', {'reason': reason});
  }

  Future<void> _updateStatusById(int id, String status, [dynamic result]) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (result != null) {
        try {
          updates['result'] = result is String ? result : jsonEncode(result);
        } catch (_) {
          updates['result'] = result.toString();
        }
      }
      final res = await _supabase.from(_activeTable).update(updates).eq('id', id).execute();
      if (res.error != null) {
        print('[SupabaseListener] updateStatus error id=$id: ${res.error!.message}');
      }
    } catch (e) {
      print('[SupabaseListener] updateStatus error id=$id: $e');
    }
  }

  // heartbeat / presence helpers
  Future<void> _setDeviceOnline(bool online) async {
    try {
      final res = await _supabase.from('devices').upsert({
        'id': deviceId,
        'online': online,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).execute();
      if (res.error != null) {
        print('[SupabaseListener] setDeviceOnline error: ${res.error!.message}');
      }
    } catch (e) {
      print('[SupabaseListener] setDeviceOnline error: $e');
    }
  }

  Future<void> _setDeviceHeartbeat() async {
    try {
      final res = await _supabase.from('devices').update({
        'online': true,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', deviceId).execute();
      if (res.error != null) {
        print('[SupabaseListener] heartbeat error: ${res.error!.message}');
      }
    } catch (e) {
      print('[SupabaseListener] heartbeat error: $e');
    }
  }
}
