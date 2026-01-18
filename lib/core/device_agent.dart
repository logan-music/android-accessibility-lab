import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart'; // MediaType
// CommandParser & CommandDispatcher already in project
import 'command_parser.dart';
import '../platform/command_dispatcher.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // Config (call configure early)
  late String supabaseUrl;
  late String deviceId;

  final http.Client _http = http.Client();
  Timer? _pollTimer;
  bool _running = false;
  bool _busy = false;

  static const Duration pollInterval = Duration(seconds: 5);

  // Device API key expected by your Edge Functions (secret you set)
  static const String deviceApiKey = 'Masena33';

  Future<void> configure({
    required String supabaseUrl,
    required String deviceId,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.deviceId = deviceId;
  }

  /// Register device (POST /register-device)
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

    await _pollOnce(); // immediate
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
      // GET /get-commands?limit=5 with x-device-id header (edge expects this)
      final res = await _get('/get-commands', query: {'limit': '5'});

      final List<dynamic> cmds = (res['commands'] ?? res['data'] ?? []) as List<dynamic>;
      for (final c in cmds) {
        if (c is Map<String, dynamic>) {
          await _handleCommand(c);
        } else if (c is Map) {
          // defensive
          await _handleCommand(Map<String, dynamic>.from(c));
        }
      }
    } catch (e) {
      // silent log to avoid noisy UI; you can print for debug
      // print('[DeviceAgent] poll error: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> raw) async {
    final parsed = CommandParser.parse(raw, deviceId);

    if (parsed.error != null) {
      // try to update remote with failure
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

    final success = result['success'] == true;
    await _updateCommandStatus(cmd.id, success ? 'done' : 'failed', result);
  }

  Future<void> _updateCommandStatus(String id, String status, Map<String, dynamic> result) async {
    await _post('/update-command', {
      'id': id,
      'status': status,
      'result': result,
      'device_id': deviceId, // extra safety for server-side check
    });
  }

  // Heartbeat / touch device
  Future<void> heartbeat() async {
    await _post('/touch-device', {
      'device_id': deviceId,
    });
  }

  /// Upload file bytes to upload-file edge function (multipart/form-data)
  Future<Map<String, dynamic>> uploadFile({
    required String path,
    required List<int> bytes,
    required String contentType,
    String bucket = 'device-uploads',
    String? dest,
  }) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');
    final req = http.MultipartRequest('POST', uri)
      ..headers['x-device-api-key'] = deviceApiKey
      ..headers['X-Device-ID'] = deviceId
      ..fields['device_id'] = deviceId
      ..fields['bucket'] = bucket
      ..fields['dest'] = dest ?? path.split('/').last;

    final mediaType = _parseMediaType(contentType);

    req.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: path.split('/').last,
      contentType: mediaType,
    ));

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      try {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        return {'success': true, 'status': resp.statusCode, 'text': resp.body};
      }
    } else {
      throw Exception('upload failed ${resp.statusCode}: ${resp.body}');
    }
  }

  // ---------------- HTTP helpers ----------------

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1$path');

    final res = await _http.post(uri,
        headers: {
          'Content-Type': 'application/json',
          'x-device-api-key': deviceApiKey,
          'X-Device-ID': deviceId,
        },
        body: jsonEncode(body)).timeout(const Duration(seconds: 12));

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

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) async {
    var uri = Uri.parse('$supabaseUrl/functions/v1$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }

    final res = await _http.get(uri, headers: {
      'Accept': 'application/json',
      'x-device-api-key': deviceApiKey,
      'X-Device-ID': deviceId,
    }).timeout(const Duration(seconds: 10));

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
      final mt = MediaType.parse(s);
      return mt;
    } catch (_) {
      return MediaType('application', 'octet-stream');
    }
  }
}
