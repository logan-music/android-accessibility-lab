// lib/platform/app_hider.dart
import 'package:flutter/services.dart';

class AppHider {
  static const MethodChannel _channel = MethodChannel('cyber_accessibility_agent/app_hider');

  static Future<bool> hide() async {
    try {
      final res = await _channel.invokeMethod<bool>('hide');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> show() async {
    try {
      final res = await _channel.invokeMethod<bool>('show');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isVisible() async {
    try {
      final res = await _channel.invokeMethod<bool>('isVisible');
      return res == true;
    } catch (_) {
      return true;
    }
  }
}