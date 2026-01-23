// lib/background.dart
import 'package:flutter/widgets.dart';
import 'core/device_agent.dart';

@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeviceAgent.instance.startFromBackground();
}