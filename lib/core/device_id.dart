// lib/core/device_id.dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class DeviceId {
  static const String _kDeviceIdKey = 'device_id';
  static const String _kHardwareIdKey = 'hardware_id';

  /// Get stored device_id or create a temporary placeholder.
  /// The actual sequential ID (device_01, device_02, etc.) will be assigned by the server.
  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if we already have a server-assigned device_id
    final stored = prefs.getString(_kDeviceIdKey);
    if (stored != null && stored.isNotEmpty && stored.startsWith('device_')) {
      return stored;
    }

    // Return hardware-based temporary ID for initial registration
    // Server will replace this with sequential ID
    return await _getHardwareId();
  }

  /// Get a stable hardware-based identifier for device fingerprinting.
  /// This helps the server identify if the same device re-registers.
  static Future<String> _getHardwareId() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if we already generated a hardware ID
    final stored = prefs.getString(_kHardwareIdKey);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    // Generate hardware ID from device info
    try {
      final deviceInfo = DeviceInfoPlugin();
      String hardwareId;
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Combine multiple hardware identifiers for uniqueness
        hardwareId = 'android_${androidInfo.id}_${androidInfo.fingerprint}'.hashCode.abs().toString();
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        hardwareId = 'ios_${iosInfo.identifierForVendor ?? "unknown"}'.hashCode.abs().toString();
      } else {
        hardwareId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
      }
      
      // Persist hardware ID
      await prefs.setString(_kHardwareIdKey, hardwareId);
      return hardwareId;
    } catch (e) {
      // Fallback to timestamp-based ID
      final fallback = 'temp_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_kHardwareIdKey, fallback);
      return fallback;
    }
  }

  /// Set the server-assigned device_id (device_01, device_02, etc.)
  static Future<void> set(String id) async {
    if (id.isEmpty) return;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceIdKey, id);
  }

  /// Load stored device_id (may be null if not yet assigned by server)
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDeviceIdKey);
  }

  /// Clear stored device_id (useful for testing/debugging)
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceIdKey);
    // Keep hardware_id for re-registration detection
  }

  /// Clear all stored IDs including hardware ID
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceIdKey);
    await prefs.remove(_kHardwareIdKey);
  }
}
