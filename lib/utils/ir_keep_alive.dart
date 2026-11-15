import 'dart:convert';

import 'package:flutter/services.dart';

/// Keeps long IR tests alive in the background.
///
/// A test sweep (signal tester or finder run) is driven by Dart timers inside
/// this isolate. Android freezes or kills a backgrounded app, which silently
/// stops the sweep - and a vendor task killer (MIUI/HyperOS powerkeeper) even
/// kills a foreground service. Three native doors fight back:
///
///  * a `specialUse` foreground service with a live progress notification;
///  * an exact-alarm chain + persisted job that restart the service;
///  * a native NEC fallback that keeps sending the sweep while Dart is dead.
///
/// Every call is fail-soft: on a platform (or a build) without the native
/// channel the test simply keeps working in the foreground as before.
class IrKeepAlive {
  const IrKeepAlive._();

  static const MethodChannel _channel = MethodChannel('org.nslabs/ir_keep_alive');

  /// Native sweep modes. `nec` means the native fallback can carry on alone.
  static const String modeNec = 'nec';
  static const String modePlain = 'plain';

  /// Starts (or refreshes) the foreground service. Returns whether the native
  /// side accepted it.
  ///
  /// [mode] + the sweep position are stored natively so a revived service
  /// resumes at the exact code Dart reached instead of starting over.
  static Future<bool> start({
    required String title,
    String text = '',
    String mode = modePlain,
    int device = 0,
    int command = 0,
    int sent = 0,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('start', {
        'title': title,
        'text': text,
        'mode': mode,
        'device': device,
        'command': command,
        'sent': sent,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reports that Dart is alive and standing on this sweep position. A gap
  /// longer than a few seconds is what tells the native side to take over.
  static Future<void> beat({
    String mode = modePlain,
    int device = 0,
    int command = 0,
    int sent = 0,
  }) async {
    try {
      await _channel.invokeMethod<void>('beat', {
        'mode': mode,
        'device': device,
        'command': command,
        'sent': sent,
      });
    } catch (_) {
      // A missed beat only delays the takeover; it never breaks the sweep.
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

  /// Takes the signals the native fallback sent while Dart was dead and clears
  /// the native buffer, so they can be merged into the IR Log exactly once.
  static Future<List<Map<String, dynamic>>> drainNativeLog() async {
    try {
      final raw = await _channel.invokeMethod<String>('readNativeLog');
      return _parseEntries(raw);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clearNativeLog() async {
    try {
      await _channel.invokeMethod<void>('clearNativeLog');
    } catch (_) {}
  }

  /// Survival-ladder diagnostics: revives, native sends, heartbeat age, ...
  static Future<Map<String, dynamic>> guardState() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('guardState');
      return result ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// False on a phone that will happily kill a long background test.
  static Future<bool> get isIgnoringBatteryOptimizations async {
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system screen where the app can be excluded from battery
  /// optimization. Returns whether a screen was actually opened.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static List<Map<String, dynamic>> _parseEntries(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry('$k', v)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
