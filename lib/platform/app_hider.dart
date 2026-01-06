// lib/platform/app_hider.dart
import 'package:flutter/services.dart';

class AppHider {
  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/app_hider');

  /// Hides the launcher icon. Returns true on success.
  static Future<bool> hide() async {
    try {
      final res = await _channel.invokeMethod<bool>('hide');
      return res == true;
    } catch (e) {
      // optional: print('AppHider.hide error: $e');
      return false;
    }
  }

  /// Shows the launcher icon. Returns true on success.
  static Future<bool> show() async {
    try {
      final res = await _channel.invokeMethod<bool>('show');
      return res == true;
    } catch (e) {
      // optional: print('AppHider.show error: $e');
      return false;
    }
  }

  /// Returns whether the launcher icon is currently visible.
  static Future<bool> isVisible() async {
    try {
      final res = await _channel.invokeMethod<bool>('isVisible');
      // default true if plugin not available / unexpected response
      return res != false;
    } catch (e) {
      return true;
    }
  }
}
