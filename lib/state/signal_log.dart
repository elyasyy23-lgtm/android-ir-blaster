import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/ir_keep_alive.dart';

/// One IR transmission exactly as it went to the transmitter hardware.
@immutable
class SignalLogEntry {
  const SignalLogEntry({
    required this.at,
    required this.label,
    required this.protocol,
    required this.hex,
    required this.frequencyHz,
    required this.patternLength,
    required this.source,
    this.error,
  });

  final DateTime at;
  final String label;
  final String protocol;
  final String hex;
  final int frequencyHz;
  final int patternLength;
  final String source;

  /// Non-null when the transmitter rejected the signal.
  final String? error;

  bool get failed => error != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at.millisecondsSinceEpoch,
        'label': label,
        'protocol': protocol,
        'hex': hex,
        'freq': frequencyHz,
        'marks': patternLength,
        'source': source,
        if (error != null) 'error': error,
      };

  static SignalLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? at = raw['at'];
    if (at is! int) return null;
    return SignalLogEntry(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      label: '${raw['label'] ?? ''}',
      protocol: '${raw['protocol'] ?? ''}',
      hex: '${raw['hex'] ?? ''}',
      frequencyHz: raw['freq'] is int ? raw['freq'] as int : 0,
      patternLength: raw['marks'] is int ? raw['marks'] as int : 0,
      source: '${raw['source'] ?? ''}',
      error: raw['error'] is String ? raw['error'] as String : null,
    );
  }
}

/// In-memory ring buffer of sent signals, persisted so the history survives
/// restarts. Newest entry first.
class SignalLog extends ChangeNotifier {
  SignalLog._();

  static final SignalLog instance = SignalLog._();

  static const int maxEntries = 400;
  static const String _prefsKey = 'ir_signal_log_v1';

  final List<SignalLogEntry> _entries = <SignalLogEntry>[];
  Future<void>? _loading;

  List<SignalLogEntry> get entries => List<SignalLogEntry>.unmodifiable(_entries);
  int get count => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Safe to call many times; the first call wins.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final Object? item in decoded) {
            final SignalLogEntry? entry = SignalLogEntry.fromJson(item);
            if (entry != null) _entries.add(entry);
          }
        }
      }
    } catch (_) {
      // A corrupt log must never block the app.
    }
    _entries.sort((a, b) => b.at.compareTo(a.at));
    notifyListeners();
  }

  Future<void> add(SignalLogEntry entry) async {
    await load();
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    await _persist();
  }

  /// Merges the signals the NATIVE fallback sent while the Dart isolate was dead
  /// (vendor task killer). The native buffer is drained, so calling this twice
  /// cannot duplicate rows; rows are fingerprinted as a second safety net.
  ///
  /// This is what makes the IR log honest: a signal that left the emitter with
  /// no Flutter code running still appears in the history, tagged `(native)`.
  Future<void> syncNativeSends() async {
    final List<Map<String, dynamic>> rows = await IrKeepAlive.drainNativeLog();
    if (rows.isEmpty) return;
    await load();
    int added = 0;
    for (final Map<String, dynamic> row in rows) {
      final SignalLogEntry? parsed = SignalLogEntry.fromJson(row);
      if (parsed == null) continue;
      final SignalLogEntry entry = SignalLogEntry(
        at: parsed.at,
        label: parsed.label,
        protocol: parsed.protocol,
        hex: parsed.hex,
        frequencyHz: parsed.frequencyHz,
        patternLength: parsed.patternLength,
        source: parsed.source.contains('(native)')
            ? parsed.source
            : '${parsed.source} (native)'.trim(),
      );
      final bool duplicate = _entries.any(
        (SignalLogEntry e) =>
            e.at.millisecondsSinceEpoch == entry.at.millisecondsSinceEpoch &&
            e.hex == entry.hex,
      );
      if (duplicate) continue;
      _entries.add(entry);
      added++;
    }
    if (added == 0) return;
    _entries.sort((a, b) => b.at.compareTo(a.at));
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // Nothing else to do: the in-memory log is already cleared.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<Map<String, dynamic>>[
          for (final SignalLogEntry e in _entries) e.toJson(),
        ]),
      );
    } catch (_) {
      // Persistence is best-effort; the live log still works.
    }
  }
}

/// Fire-and-forget recorder used from the transmitter layer.
void recordIrSend({
  required String label,
  required String protocol,
  String? hex,
  required int frequencyHz,
  int patternLength = 0,
  String source = 'Remote',
  Object? error,
}) {
  final String cleanLabel = label.trim();
  final String cleanProtocol = protocol.trim();
  final String cleanHex = (hex ?? '').trim();
  unawaited(
    SignalLog.instance.add(
      SignalLogEntry(
        at: DateTime.now(),
        label: cleanLabel.isEmpty ? source : cleanLabel,
        protocol: cleanProtocol.isEmpty ? 'RAW' : cleanProtocol,
        hex: cleanHex.isEmpty ? '—' : cleanHex,
        frequencyHz: frequencyHz,
        patternLength: patternLength,
        source: source,
        error: error?.toString(),
      ),
    ),
  );
}
