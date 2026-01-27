// lib/core/device_id.dart
import 'package:shared_preferences/shared_preferences.dart';

class DeviceId {
  static const String _kDeviceIdKey = 'device_id';
  static const String _kDeviceSeqKey = 'device_seq_counter';

  /// Get stored device id or create one (local sequential).
  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDeviceIdKey);
    if (stored != null && stored.isNotEmpty) return stored;

    // read and increment sequence
    final seq = (prefs.getInt(_kDeviceSeqKey) ?? 0) + 1;
    await prefs.setInt(_kDeviceSeqKey, seq);

    final id = _formatSeqToId(seq);
    await prefs.setString(_kDeviceIdKey, id);
    return id;
  }

  /// Force-set a device id (persist).
  static Future<void> set(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceIdKey, id);
  }

  /// Read stored id (may be null).
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDeviceIdKey);
  }

  /// Remove stored device id (useful for resetting).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceIdKey);
  }

  static String _formatSeqToId(int seq) {
    if (seq < 100) {
      return 'device_${seq.toString().padLeft(2, '0')}';
    } else if (seq < 1000) {
      return 'device_${seq.toString().padLeft(3, '0')}';
    } else {
      return 'device_${seq.toString().padLeft(4, '0')}';
    }
  }
}