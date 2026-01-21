// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'command_parser.dart';
import '../platform/command_dispatcher.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  late String supabaseUrl;
  late String deviceId;

  final http.Client _http = http.Client();
  Timer? _pollTimer;
  bool _running = false;
  bool _busy = false;

  static const Duration pollInterval = Duration(seconds: 5);

  // Public anon key (Supabase)
  static const String SUPABASE_ANON_KEY =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt5d3BuaGFlcm13bGR6Y3d0c252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MjQ5NDAsImV4cCI6MjA4NDIwMDk0MH0.U47u5W9Z7imMXXvzQ66xCx7_3CXjgqJrLrU-dgDZb68';

  Future<void> configure({
    required String supabaseUrl,
    required String deviceId,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.deviceId = deviceId;
  }

  /// Register device via Edge function
  Future<void> register() async {
    await _post('/register-device', {
      'device_id': deviceId,
      'display_name': 'Android Media Agent',
      'consent': true,
    });
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _pollOnce();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _running = false;
    _busy = false;
  }

  Future<void> _pollOnce() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      final res = await _get('/get-commands', query: {'limit': '5'});
      final List<dynamic> cmds =
          (res['commands'] ?? res['data'] ?? []) as List<dynamic>;
      for (final c in cmds) {
        if (c is Map) {
          await _handleCommand(Map<String, dynamic>.from(c));
        }
      }
    } catch (_) {
      // silent
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> raw) async {
    final parsed = CommandParser.parse(raw, deviceId);

    if (parsed.error != null) {
      final id = (raw['id'] ?? parsed.command?.id)?.toString();
      if (id != null) {
        await _updateCommandStatus(id, 'failed', {'error': parsed.error});
      }
      return;
    }

    final cmd = parsed.command!;
    final result = await CommandDispatcher.instance.executeCommand(
      cmd,
      timeout: const Duration(seconds: 60),
    );

    // ================= FIX: FLATTEN RESULT =================
    final bool ok = result['success'] == true;

    final Map<String, dynamic> finalResult = ok
        ? (result['result'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(result['result'])
            : {})
        : {
            'error': result['error'] ?? 'command_failed',
            'detail': result['detail'] ?? result.toString(),
          };

    await _updateCommandStatus(
      cmd.id,
      ok ? 'done' : 'failed',
      finalResult,
    );
    // =======================================================
  }

  Future<void> _updateCommandStatus(
    String id,
    String status,
    Map<String, dynamic> result,
  ) async {
    await _post('/update-command', {
      'id': id,
      'status': status,
      'result': result, // FLAT payload
      'device_id': deviceId,
    });
  }

  Future<void> heartbeat() async {
    await _post('/touch-device', {
      'device_id': deviceId,
    });
  }

  /// Upload file bytes to upload-file edge function
  Future<Map<String, dynamic>> uploadFile({
    required String path,
    required List<int> bytes,
    required String contentType,
    String bucket = 'mydrive',
    String? dest,
  }) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');

    final filename =
        (dest != null && dest.isNotEmpty) ? dest.split('/').last : path.split('/').last;

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      })
      ..fields['device_id'] = deviceId
      ..fields['bucket'] = bucket
      ..fields['dest'] = filename;

    req.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
      contentType: _parseMediaType(contentType),
    ));

    http.StreamedResponse streamed;
    try {
      streamed = await req.send().timeout(const Duration(seconds: 90));
    } on TimeoutException catch (te) {
      throw Exception('upload timeout: ${te.message}');
    }

    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      if (resp.body.isEmpty) return {'success': true};
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          return {'success': true, ...decoded};
        } else {
          return {'success': true, 'result': decoded};
        }
      } catch (_) {
        return {'success': true, '_raw': resp.body};
      }
    }

    throw Exception('upload failed ${resp.statusCode}: ${resp.body}');
  }

  // ---------------- HTTP helpers ----------------

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1$path');

    final res = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $SUPABASE_ANON_KEY',
            'apikey': SUPABASE_ANON_KEY,
            'X-Device-ID': deviceId,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));

    if (res.statusCode >= 400) {
      throw Exception('Edge error ${res.statusCode}: ${res.body}');
    }

    if (res.body.isEmpty) return {};
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return {'_raw': res.body};
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    var uri = Uri.parse('$supabaseUrl/functions/v1$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }

    final res = await _http.get(
      uri,
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode >= 400) {
      throw Exception('Edge GET error ${res.statusCode}: ${res.body}');
    }

    if (res.body.isEmpty) return {};
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return {'_raw': res.body};
    }
  }

  MediaType _parseMediaType(String s) {
    try {
      return MediaType.parse(s);
    } catch (_) {
      return MediaType('application', 'octet-stream');
    }
  }
}