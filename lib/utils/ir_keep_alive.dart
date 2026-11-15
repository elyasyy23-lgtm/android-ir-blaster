import 'package:flutter/services.dart';

/// Keeps long IR tests alive in the background.
///
/// A test sweep (signal tester or finder run) is driven by Dart timers inside
/// this isolate. Android freezes or kills a backgrounded app, which silently
/// stops the sweep. Starting this foreground service pins the process up and
/// shows a live progress notification with a Stop action.
///
/// Every call is fail-soft: on a platform (or a build) without the native
/// channel the test simply keeps working in the foreground as before.
class IrKeepAlive {
  const IrKeepAlive._();

  static const MethodChannel _channel = MethodChannel('org.nslabs/ir_keep_alive');

  /// Starts (or refreshes) the foreground service. Returns whether the native
  /// side accepted it.
  static Future<bool> start({required String title, String text = ''}) async {
    try {
      final result = await _channel.invokeMethod<bool>('start', {
        'title': title,
        'text': text,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Updates the notification body. Cheap enough to call once per sent signal,
  /// but the caller should throttle it (see [shouldUpdate]).
  static Future<void> update({required String title, String text = ''}) async {
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title,
        'text': text,
      });
    } catch (_) {
      // Notification updates are cosmetic; never break a run for them.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<bool> get isRunning async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when the user tapped Stop in the notification.
  static Future<bool> get stopRequested async {
    try {
      return await _channel.invokeMethod<bool>('stopRequested') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Clears a previously observed stop request before a new run starts.
  static Future<void> clearStopRequest() async {
    try {
      await _channel.invokeMethod<void>('clearStopRequest');
    } catch (_) {}
  }

  /// Notification text should not be rewritten for every single signal.
  static bool shouldUpdate(int sentCount) => sentCount <= 3 || sentCount % 3 == 0;
}
