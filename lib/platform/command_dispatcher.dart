// lib/platform/command_dispatcher.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/command_parser.dart';
import '../core/device_agent.dart';
import '../core/command_executor.dart';

class CommandDispatcher {
  CommandDispatcher._();
  static final CommandDispatcher instance = CommandDispatcher._();

  static const MethodChannel _channel =
      MethodChannel('cyber_accessibility_agent/commands');

  final CommandExecutor _executor = CommandExecutor.instance;

  /// Main dispatch: route command to appropriate handler
  Future<Map<String, dynamic>> dispatch(Command cmd) async {
    print('[CommandDispatcher] Dispatching command: ${cmd.action.name}');
    
    // ✅ FIX 1: Handle sendTelegram specially - it needs file access + Telegram API
    if (cmd.action == CommandAction.sendTelegram) {
      return await _handleTelegramSend(cmd);
    }

    // ✅ FIX 2: Only handle content:// for upload/read actions, not all commands
    final path = cmd.payload['path'];
    if (path is String && path.startsWith('content://') && Platform.isAndroid) {
      // Content URIs only make sense for upload, read, or prepare actions
      if (cmd.action == CommandAction.uploadFile || 
          cmd.action == CommandAction.readFile ||
          cmd.action == CommandAction.prepareUpload) {
        print('[CommandDispatcher] Handling content URI for ${cmd.action.name}');
        return await _handleContentUriUpload(cmd, path);
      }
      // For other commands with content URIs, let executor handle it
      print('[CommandDispatcher] Content URI in ${cmd.action.name} - passing to executor');
    }

    // ✅ FIX 3: Default route to executor for normal commands
    return await _executor.execute(cmd);
  }

  /// Execute command with timeout and retry logic
  Future<Map<String, dynamic>> executeCommand(
    Command cmd, {
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 2,
  }) async {
    int attempt = 0;
    const baseDelayMs = 300;
    Exception? lastException;
    StackTrace? lastStack;

    while (true) {
      attempt++;
      print('[CommandDispatcher] Attempt $attempt/$maxRetries for command ${cmd.id}');
      
      try {
        final res = await dispatch(cmd).timeout(timeout);
        
        // ✅ FIX 4: Validate response structure
        if (res is! Map<String, dynamic>) {
          print('[CommandDispatcher] Invalid response type: ${res.runtimeType}');
          return {
            'success': false, 
            'error': 'invalid_response_type',
            'detail': 'Expected Map but got ${res.runtimeType}'
          };
        }
        
        print('[CommandDispatcher] Command ${cmd.id} completed: ${res['success'] == true ? 'success' : 'failed'}');
        return res;
        
      } on TimeoutException catch (e, st) {
        print('[CommandDispatcher] Timeout on attempt $attempt: $e');
        lastException = e;
        lastStack = st;
        
        if (attempt > maxRetries) {
          return {
            'success': false, 
            'error': 'command_timeout',
            'detail': 'Command timed out after $attempt attempts',
            'timeout_seconds': timeout.inSeconds,
            'attempts': attempt
          };
        }
        
      } catch (e, st) {
        print('[CommandDispatcher] Exception on attempt $attempt: $e\n$st');
        lastException = e as Exception;
        lastStack = st;
        
        if (attempt > maxRetries) {
          return {
            'success': false, 
            'error': 'dispatcher_failed',
            'detail': e.toString(),
            'stack_trace': st.toString().split('\n').take(5).join('\n'),
            'attempts': attempt
          };
        }
      }

      // ✅ FIX 5: Exponential backoff with logging
      final delayMs = baseDelayMs * (1 << (attempt - 1));
      final actualDelay = delayMs > 5000 ? 5000 : delayMs;
      print('[CommandDispatcher] Retrying after ${actualDelay}ms...');
      await Future.delayed(Duration(milliseconds: actualDelay));
    }
  }

  // ✅ NEW: Handle Telegram send separately
  Future<Map<String, dynamic>> _handleTelegramSend(Command cmd) async {
    print('[CommandDispatcher] Handling Telegram send');
    
    final path = cmd.payload['path'];
    final telegram = cmd.payload['telegram'];

    if (path == null || path.toString().isEmpty) {
      return {'success': false, 'error': 'missing_path', 'detail': 'Telegram send requires path'};
    }

    if (telegram == null || telegram is! Map) {
      return {
        'success': false, 
        'error': 'missing_telegram_config',
        'detail': 'Telegram send requires telegram config with bot_token and chat_id'
      };
    }

    try {
      final pathStr = path.toString();
      final telegramMap = Map<String, dynamic>.from(telegram as Map);

      // ✅ Handle content URI for Telegram send
      if (pathStr.startsWith('content://') && Platform.isAndroid) {
        print('[CommandDispatcher] Reading content URI for Telegram send: $pathStr');
        
        final raw = await _channel.invokeMethod<dynamic>('readContentUri', {'uri': pathStr});
        if (raw == null || raw is! Map) {
          return {'success': false, 'error': 'native_read_failed', 'detail': 'Invalid native response'};
        }

        final result = Map<String, dynamic>.from(raw);
        final String? b64 = (result['b64'] ?? result['file_b64'] ?? result['fileB64'])?.toString();
        
        if (b64 == null || b64.isEmpty) {
          return {'success': false, 'error': 'no_file_bytes', 'detail': 'Content URI read returned no data'};
        }

        List<int> bytes;
        try {
          bytes = base64Decode(b64);
        } catch (e) {
          return {'success': false, 'error': 'base64_decode_failed', 'detail': e.toString()};
        }

        final filename = (result['filename'] ?? 'file_${DateTime.now().millisecondsSinceEpoch}').toString();
        
        // Create temp file for Telegram send
        final tempDir = Directory.systemTemp;
        final tempFile = File('${tempDir.path}/$filename');
        await tempFile.writeAsBytes(bytes);

        // Now send via Telegram using the temp file path
        final sendResult = await _sendToTelegram(tempFile.path, telegramMap);
        
        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}

        return sendResult;
      }

      // ✅ Handle regular file path
      return await _sendToTelegram(pathStr, telegramMap);
      
    } catch (e, st) {
      print('[CommandDispatcher] Telegram send exception: $e\n$st');
      return {
        'success': false, 
        'error': 'telegram_send_exception',
        'detail': e.toString()
      };
    }
  }

  // ✅ NEW: Direct Telegram API call
  Future<Map<String, dynamic>> _sendToTelegram(
    String filePath, 
    Map<String, dynamic> telegram
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return {'success': false, 'error': 'file_not_found', 'path': filePath};
      }

      final botToken = telegram['bot_token'] ?? telegram['token'] ?? telegram['botToken'];
      final chatId = telegram['chat_id'] ?? telegram['chatId'] ?? telegram['chat'];

      if (botToken == null || chatId == null) {
        return {
          'success': false,
          'error': 'missing_telegram_credentials',
          'detail': 'Requires bot_token and chat_id'
        };
      }

      final filename = filePath.split('/').last;
      final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendDocument');

      print('[CommandDispatcher] Sending $filename to Telegram chat $chatId...');

      final req = http.MultipartRequest('POST', uri)
        ..fields['chat_id'] = chatId.toString()
        ..files.add(
          http.MultipartFile.fromBytes(
            'document',
            await file.readAsBytes(),
            filename: filename,
            contentType: MediaType.parse(_guessMimeType(filename)),
          ),
        );

      final streamedResp = await req.send().timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamedResp);

      print('[CommandDispatcher] Telegram API response: ${resp.statusCode}');

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final decoded = jsonDecode(resp.body);
          return {
            'success': true,
            'message': 'File sent to Telegram successfully',
            'filename': filename,
            'chat_id': chatId,
            'telegram_response': decoded
          };
        } catch (_) {
          return {
            'success': true,
            'message': 'File sent to Telegram successfully',
            'filename': filename
          };
        }
      }

      // Parse error from Telegram
      try {
        final decoded = jsonDecode(resp.body);
        return {
          'success': false,
          'error': 'telegram_api_error',
          'status': resp.statusCode,
          'description': decoded['description'] ?? 'Unknown error',
          'telegram_response': decoded
        };
      } catch (_) {
        return {
          'success': false,
          'error': 'telegram_api_error',
          'status': resp.statusCode,
          'body': resp.body
        };
      }
    } catch (e, st) {
      print('[CommandDispatcher] Telegram send failed: $e\n$st');
      return {
        'success': false, 
        'error': 'telegram_send_failed',
        'detail': e.toString()
      };
    }
  }

  /// Handle content URI uploads (for upload_file action only)
  Future<Map<String, dynamic>> _handleContentUriUpload(Command cmd, String uri) async {
    print('[CommandDispatcher] Reading content URI: $uri');
    
    try {
      final raw = await _channel.invokeMethod<dynamic>('readContentUri', {'uri': uri});
      
      if (raw == null || raw is! Map) {
        return {
          'success': false, 
          'error': 'native_read_failed',
          'detail': 'Native method returned invalid response'
        };
      }

      final result = Map<String, dynamic>.from(raw);
      
      if (result['success'] == false) {
        return {
          'success': false,
          'error': 'content_uri_read_failed',
          'detail': result['error'] ?? result['detail'] ?? 'Unknown error'
        };
      }

      final String? b64 = (result['b64'] ?? result['file_b64'] ?? result['fileB64'])?.toString();
      final meta = result['meta'] ?? result['metadata'];
      final filename = (result['filename'] ?? 
                       (meta is Map ? meta['display_name'] ?? meta['name'] : null))?.toString() ?? 
                       'content_${DateTime.now().millisecondsSinceEpoch}';
      final contentType = (result['content_type'] ?? 
                          (meta is Map ? meta['mime'] : null) ?? 
                          'application/octet-stream').toString();

      if (b64 == null || b64.isEmpty) {
        return {'success': false, 'error': 'no_file_bytes', 'detail': 'Content URI returned no data'};
      }

      List<int> bytes;
      try {
        bytes = base64Decode(b64);
        print('[CommandDispatcher] Decoded ${bytes.length} bytes from content URI');
      } catch (e) {
        return {'success': false, 'error': 'base64_decode_failed', 'detail': e.toString()};
      }

      // ✅ FIX 6: Handle different action types
      if (cmd.action == CommandAction.readFile) {
        // Just return the decoded data
        return {
          'success': true,
          'file_b64': b64,
          'filename': filename,
          'content_type': contentType,
          'size': bytes.length,
        };
      }

      if (cmd.action == CommandAction.prepareUpload) {
        // Return metadata only
        return {
          'success': true,
          'is_content_uri': true,
          'uri': uri,
          'name': filename,
          'size': bytes.length,
          'content_type': contentType,
        };
      }

      // Default: upload to Supabase
      final bucket = (cmd.payload['bucket'] as String?) ?? 'device-uploads';
      final dest = (cmd.payload['dest'] as String?) ?? filename;

      print('[CommandDispatcher] Uploading content URI to Supabase: $filename');

      try {
        final uploadRes = await DeviceAgent.instance.uploadFile(
          path: filename,
          bytes: bytes,
          contentType: contentType,
          bucket: bucket,
          dest: dest,
        );

        if (uploadRes['success'] == true) {
          print('[CommandDispatcher] Content URI upload successful');
          return {
            'success': true,
            'filename': filename,
            'size': bytes.length,
            'content_type': contentType,
            ...uploadRes
          };
        }

        print('[CommandDispatcher] Content URI upload failed: ${uploadRes['error']}');
        return {
          'success': false,
          'error': uploadRes['error'] ?? 'upload_failed',
          'detail': uploadRes['detail'] ?? uploadRes.toString()
        };
      } catch (e, st) {
        print('[CommandDispatcher] Upload exception: $e\n$st');
        return {
          'success': false, 
          'error': 'upload_exception',
          'detail': e.toString()
        };
      }
    } catch (e, st) {
      print('[CommandDispatcher] Content URI exception: $e\n$st');
      return {
        'success': false, 
        'error': 'content_uri_exception',
        'detail': e.toString()
      };
    }
  }

  String _guessMimeType(String filename) {
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
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}