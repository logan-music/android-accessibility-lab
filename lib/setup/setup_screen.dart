// lib/setup/setup_screen.dart
import 'package:flutter/material.dart';
import '../core/device_agent.dart';
import '../core/device_id.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String _status = 'Ready';

  Future<void> _register() async {
    setState(() => _status = 'Registering...');
    final res = await DeviceAgent.instance.registerDevice(manual: true);
    setState(() => _status = res != null ? 'Registered: ${res.toString()}' : 'Register failed');
  }

  Future<void> _showDevice() async {
    final id = await DeviceId.load();
    setState(() => _status = 'Device: ${id ?? "(none)"}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(_status),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _register, child: const Text('Register device')),
          ElevatedButton(onPressed: _showDevice, child: const Text('Show saved device id')),
        ]),
      ),
    );
  }
}
