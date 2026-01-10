import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Helper for device id lifecycle (generate next device_XX, persist, swap).
class DeviceId {
  static const String _kDeviceIdKey = 'device_id';
  static const String _kDeviceJwtKey = 'device_jwt';

  /// Get stored device id or create one (tries Supabase REST to enumerate existing ids).
  /// Returns the resulting device id and persists it to SharedPreferences.
  static Future<String> getOrCreate({
    required String supabaseUrl,
    required String anonKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDeviceIdKey);
    if (stored != null && stored.isNotEmpty) return stored;

    final generated = await _generateNextFromSupabase(supabaseUrl, anonKey);
    await prefs.setString(_kDeviceIdKey, generated);
    // ensure JWT cleared for a brand new id
    await prefs.remove(_kDeviceJwtKey);
    return generated;
  }

  /// Force-set a device id (persist and clear jwt).
  static Future<void> set(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceIdKey, id);
    await prefs.remove(_kDeviceJwtKey);
  }

  /// Swap to the next device id (uses supabase to pick next); returns new id.
  static Future<String> swap({
    required String supabaseUrl,
    required String anonKey,
  }) async {
    final next = await _generateNextFromSupabase(supabaseUrl, anonKey);
    await set(next);
    return next;
  }

  /// Read-only: load stored id (may be null).
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDeviceIdKey);
  }

  /// Remove JWT only (useful when rotating id or resetting registration).
  static Future<void> clearJwt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceJwtKey);
  }

  /// Internal: query supabase /rest/v1/devices to pick next device_{NN}
  static Future<String> _generateNextFromSupabase(String supabaseUrl, String anonKey) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/devices?select=id');
      final res = await http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body) as List;
        final ids = list
            .map((e) => e is Map ? (e['id']?.toString() ?? '') : (e?.toString() ?? ''))
            .where((s) => s.isNotEmpty)
            .toSet();

        int n = 1;
        while (n <= 9999) {
          final candidate = 'device_${n.toString().padLeft(2, '0')}';
          if (!ids.contains(candidate)) return candidate;
          n++;
        }
        // insane edge case: fallback below
      }
    } catch (_) {
      // network failure or parse error -> fallback
    }
    // fallback deterministic-ish id (timestamp+random) but still looks like device_##
    final fallbackNum = (DateTime.now().millisecondsSinceEpoch % 1000);
    final rnd = Random().nextInt(90) + 10;
    final combined = ((fallbackNum + rnd) % 99) + 1;
    return 'device_${combined.toString().padLeft(2, '0')}';
  }
}