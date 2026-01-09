import 'dart:async';

import '../core/command_parser.dart';
import '../core/command_executor.dart';

class CommandDispatcher {
  CommandDispatcher._internal();

  static final CommandDispatcher instance =
      CommandDispatcher._internal();

  final CommandExecutor _executor = CommandExecutor();

  Future<Map<String, dynamic>> dispatch(
    Command cmd, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final result = await _executor
          .execute(cmd)
          .timeout(timeout);

      return _normalize(result, cmd);
    } on TimeoutException {
      return {
        'ok': false,
        'error': 'execution_timeout',
        'command_id': cmd.id,
      };
    } catch (e, st) {
      return {
        'ok': false,
        'error': 'dispatcher_exception',
        'message': e.toString(),
        'stack': st.toString(),
        'command_id': cmd.id,
      };
    }
  }

  // --------------------------------------------------
  // NORMALIZATION
  // --------------------------------------------------

  Map<String, dynamic> _normalize(
    Map<String, dynamic> raw,
    Command cmd,
  ) {
    final ok = raw['ok'] == true;

    return {
      'ok': ok,
      'command_id': cmd.id,
      'device_id': cmd.deviceId,
      'action': cmd.action.name,
      'timestamp': DateTime.now().toUtc().toIso8601String(),

      if (ok) 'data': raw,
      if (!ok) 'error': raw['error'] ?? 'unknown_error',
      if (raw['detail'] != null) 'detail': raw['detail'],
    };
  }

  // --------------------------------------------------
  // DEBUG HELPERS
  // --------------------------------------------------

  String formatForLog(Map<String, dynamic> res) {
    if (res['ok'] == true) {
      return '[OK] ${res['action']} (${res['command_id']})';
    }
    return '[ERR] ${res['action']} → ${res['error']}';
  }
}
