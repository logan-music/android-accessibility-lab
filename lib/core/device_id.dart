import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Helper for device id lifecycle (generate, persist, swap).
/// Does NOT directly hit Supabase REST. All registration is via Edge function.
class DeviceId {
  static const String _kDeviceIdKey = 'device_id';
  static const String _kDeviceJwtKey = 'device_jwt';

  /// Get stored device id or create a fallback one (local only)
  static Future<String> getOrCreate({
    required String supabaseUrl,
    required String anonKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDeviceIdKey);
    if (stored != null && stored.isNotEmpty) return stored;

    final generated = _generateFallbackId();
    await prefs.setString(_kDeviceIdKey, generated);
    await prefs.remove(_kDeviceJwtKey); // ensure JWT cleared
    return generated;
  }

  /// Force-set a device id (persist and clear jwt)
  static Future<void> set(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceIdKey, id);
    await prefs.remove(_kDeviceJwtKey);
  }

  /// Swap to a new device id (local fallback only)
  static Future<String> swap({
    required String supabaseUrl,
    required String anonKey,
  }) async {
    final next = _generateFallbackId();
    await set(next);
    return next;
  }

  /// Load stored id (may be null)
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDeviceIdKey);
  }

  /// Remove JWT only
  static Future<void> clearJwt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceJwtKey);
  }

  /// Generate fallback deterministic-ish id
  static String _generateFallbackId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch % 1000;
    final rnd = Random().nextInt(90) + 10;
    final num = ((timestamp + rnd) % 99) + 1;
    return 'device_${num.toString().padLeft(2, '0')}';
  }
}
