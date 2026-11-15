import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:irblaster_controller/ir/ir_protocol_registry.dart';
import 'package:irblaster_controller/state/signal_log.dart';
import 'package:irblaster_controller/utils/ir_transmitter_platform.dart';
import 'remote.dart';

const platform = MethodChannel('org.nslabs/irtransmitter');

const int kDefaultNecFrequencyHz = 38000;
const int kMinIrFrequencyHz = 15000;
const int kMaxIrFrequencyHz = 60000;

/// Everything the in-app signal log needs to describe a transmission.
@immutable
class IrSendInfo {
  const IrSendInfo({
    required this.label,
    required this.protocol,
    this.hex,
    this.source = 'Remote',
  });

  final String label;
  final String protocol;
  final String? hex;

  /// Where the send came from: Remote, Signal Tester, Macro, ...
  final String source;
}

String _hexOf(int code) => code.toRadixString(16).toUpperCase();

/// Human name of a button; text labels are stored in [IRButton.image].
String irButtonLabel(IRButton button) {
  final String raw = button.image.trim();
  if (raw.isEmpty) return 'Button';
  if (!button.isImage) return raw;
  final String cleaned = raw.replaceAll('\\', '/');
  final List<String> parts = cleaned.split('/');
  final String last = parts.isEmpty ? raw : parts.last;
  final int dot = last.lastIndexOf('.');
  final String base = dot > 0 ? last.substring(0, dot) : last;
  return base.isEmpty ? 'Button' : base;
}

/// Describes how [button] is transmitted (best effort, before encoding).
IrSendInfo describeIrButton(IRButton button, {String source = 'Remote'}) {
  final String protocolId = button.protocol?.trim() ?? '';
  final String rawData = button.rawData?.trim() ?? '';
  final String protocol;
  if (protocolId.isNotEmpty) {
    protocol = protocolId;
  } else if (rawData.isNotEmpty) {
    protocol = isNecConfigString(rawData) ? 'NEC (custom timings)' : 'RAW';
  } else if (button.code != null) {
    protocol = 'NEC';
  } else {
    protocol = 'RAW';
  }
  return IrSendInfo(
    label: irButtonLabel(button),
    protocol: protocol,
    hex: button.code == null ? null : _hexOf(button.code!),
    source: source,
  );
}

void _logSend(
  IrSendInfo info,
  int frequencyHz,
  int patternLength, {
  Object? error,
}) {
  recordIrSend(
    label: info.label,
    protocol: info.protocol,
    hex: info.hex,
    frequencyHz: frequencyHz,
    patternLength: patternLength,
    source: info.source,
    error: error,
  );
}

class NECParams {
  final int headerMark;
  final int headerSpace;
  final int bitMark;
  final int zeroSpace;
  final int oneSpace;
  final int trailerMark;

  const NECParams({
    required this.headerMark,
    required this.headerSpace,
    required this.bitMark,
    required this.zeroSpace,
    required this.oneSpace,
    required this.trailerMark,
  });

  static const NECParams defaults = NECParams(
    headerMark: 9000,
    headerSpace: 4500,
    bitMark: 560,
    zeroSpace: 560,
    oneSpace: 1690,
    trailerMark: 560,
  );
}

bool isNecConfigString(String? rawData) {
  if (rawData == null) return false;
  return rawData.trimLeft().toUpperCase().startsWith('NEC:');
}

NECParams parseNecParamsFromString(String rawData) {
  try {
    final String s = rawData.trim();
    final int idx = s.toUpperCase().indexOf('NEC:');
    if (idx != 0) return NECParams.defaults;
    final String body = s.substring(4).trim();
    if (body.contains('=') || body.contains(';')) {
      int headerMark = NECParams.defaults.headerMark;
      int headerSpace = NECParams.defaults.headerSpace;
      int bitMark = NECParams.defaults.bitMark;
      int zeroSpace = NECParams.defaults.zeroSpace;
      int oneSpace = NECParams.defaults.oneSpace;
      int trailerMark = NECParams.defaults.trailerMark;
      final parts = body.split(';');
      for (final part in parts) {
        final p = part.trim();
        if (p.isEmpty) continue;
        final eq = p.indexOf('=');
        if (eq <= 0) continue;
        final key = p.substring(0, eq).trim().toLowerCase();
        final values = p
            .substring(eq + 1)
            .split(RegExp(r'[, ]+'))
            .where((e) => e.trim().isNotEmpty)
            .toList();
        if (key == 'h' || key == 'header') {
          if (values.length >= 2) {
            headerMark = int.tryParse(values[0]) ?? headerMark;
            headerSpace = int.tryParse(values[1]) ?? headerSpace;
          }
        } else if (key == 'b' || key == 'bit') {
          if (values.length >= 3) {
            bitMark = int.tryParse(values[0]) ?? bitMark;
            zeroSpace = int.tryParse(values[1]) ?? zeroSpace;
            oneSpace = int.tryParse(values[2]) ?? oneSpace;
          }
        } else if (key == 't' || key == 'trail' || key == 'trailer') {
          if (values.isNotEmpty) {
            trailerMark = int.tryParse(values[0]) ?? trailerMark;
          }
        }
      }
      return NECParams(
        headerMark: headerMark,
        headerSpace: headerSpace,
        bitMark: bitMark,
        zeroSpace: zeroSpace,
        oneSpace: oneSpace,
        trailerMark: trailerMark,
      );
    } else {
      final nums = body
          .split(RegExp(r'[, ]+'))
          .where((e) => e.trim().isNotEmpty)
          .toList();
      if (nums.length >= 6) {
        final headerMark =
            int.tryParse(nums[0]) ?? NECParams.defaults.headerMark;
        final headerSpace =
            int.tryParse(nums[1]) ?? NECParams.defaults.headerSpace;
        final bitMark = int.tryParse(nums[2]) ?? NECParams.defaults.bitMark;
        final zeroSpace = int.tryParse(nums[3]) ?? NECParams.defaults.zeroSpace;
        final oneSpace = int.tryParse(nums[4]) ?? NECParams.defaults.oneSpace;
        final trailerMark =
            int.tryParse(nums[5]) ?? NECParams.defaults.trailerMark;
        return NECParams(
          headerMark: headerMark,
          headerSpace: headerSpace,
          bitMark: bitMark,
          zeroSpace: zeroSpace,
          oneSpace: oneSpace,
          trailerMark: trailerMark,
        );
      }
      return NECParams.defaults;
    }
  } catch (_) {
    return NECParams.defaults;
  }
}

List<int> buildNecPatternFromStoredCodeMSBFirst(int code32,
    {NECParams params = NECParams.defaults}) {
  final int nec = code32 & 0xFFFFFFFF;
  final List<int> pattern = [];
  pattern.add(params.headerMark);
  pattern.add(params.headerSpace);
  for (int i = 31; i >= 0; i--) {
    final int bit = (nec >> i) & 0x1;
    pattern.add(params.bitMark);
    if (bit == 0) {
      pattern.add(params.zeroSpace);
    } else {
      pattern.add(params.oneSpace);
    }
  }
  pattern.add(params.trailerMark);
  return pattern;
}

List<int> buildNecPatternLSBFirst(int code32,
    {NECParams params = NECParams.defaults}) {
  final int nec = code32 & 0xFFFFFFFF;
  final List<int> pattern = [];
  pattern.add(params.headerMark);
  pattern.add(params.headerSpace);
  for (int i = 0; i < 32; i++) {
    final int bit = (nec >> i) & 0x1;
    pattern.add(params.bitMark);
    pattern.add(bit == 0 ? params.zeroSpace : params.oneSpace);
  }
  pattern.add(params.trailerMark);
  return pattern;
}

List<int> buildNecPatternLsbPerByte(int code32,
    {NECParams params = NECParams.defaults}) {
  final int nec = code32 & 0xFFFFFFFF;
  final List<int> pattern = [params.headerMark, params.headerSpace];
  for (int byteShift = 24; byteShift >= 0; byteShift -= 8) {
    for (int bitIndex = 0; bitIndex < 8; bitIndex++) {
      final int bit = (nec >> (byteShift + bitIndex)) & 0x1;
      pattern.add(params.bitMark);
      pattern.add(bit == 0 ? params.zeroSpace : params.oneSpace);
    }
  }
  pattern.add(params.trailerMark);
  return pattern;
}

List<int> _buildCustomNecPattern(
  int code32, {
  required String? bitOrder,
  required NECParams params,
}) {
  switch (bitOrder?.trim().toLowerCase()) {
    case 'lsb':
      return buildNecPatternLSBFirst(code32, params: params);
    case 'true_lsb':
      return buildNecPatternLsbPerByte(code32, params: params);
    default:
      return buildNecPatternFromStoredCodeMSBFirst(code32, params: params);
  }
}

void _reportFlutterError(String where, Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'IR Blaster',
      context: ErrorDescription(where),
      informationCollector: () sync* {
        yield DiagnosticsProperty<String>('channel', platform.name);
      },
    ),
  );
}

void _validatePattern(List<int> pattern, {String where = 'pattern'}) {
  for (int i = 0; i < pattern.length; i++) {
    final v = pattern[i];
    if (v <= 0) {
      throw ArgumentError.value(v, '$where[$i]', 'Duration must be > 0 µs');
    }
  }
}

void _validateFrequency(int frequencyHz) {
  if (frequencyHz < kMinIrFrequencyHz || frequencyHz > kMaxIrFrequencyHz) {
    throw RangeError.range(
      frequencyHz,
      kMinIrFrequencyHz,
      kMaxIrFrequencyHz,
      'frequency',
      'IR carrier frequency must be between $kMinIrFrequencyHz and $kMaxIrFrequencyHz Hz',
    );
  }
}

List<int> _parseRawPattern(String rawData, {required String where}) {
  final parts = rawData
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    throw FormatException('$where is empty');
  }
  final pattern = <int>[];
  for (int i = 0; i < parts.length; i++) {
    final parsed = int.tryParse(parts[i]);
    if (parsed == null) {
      throw FormatException(
        'Invalid integer in $where at index $i: "${parts[i]}"',
      );
    }
    pattern.add(parsed);
  }
  return pattern;
}

Future<void> transmit(int code, {IrSendInfo? info}) async {
  final pattern = convertNECtoList(code);
  _validatePattern(pattern, where: 'hexPattern');
  final IrSendInfo sendInfo = info ??
      IrSendInfo(
        label: 'NEC ${_hexOf(code)}',
        protocol: 'NEC',
        hex: _hexOf(code),
        source: 'Signal Tester',
      );
  try {
    await platform.invokeMethod("transmit", {"list": pattern});
    _logSend(sendInfo, kDefaultNecFrequencyHz, pattern.length);
  } on PlatformException catch (e) {
    // Let the caller display hardware failures without creating crash reports.
    _logSend(sendInfo, kDefaultNecFrequencyHz, pattern.length,
        error: e.message ?? e.code);
    rethrow;
  } catch (e, st) {
    _reportFlutterError('transmit()', e, st);
    _logSend(sendInfo, kDefaultNecFrequencyHz, pattern.length, error: e);
    rethrow;
  }
}

Future<void> transmitRaw(int frequency, List<int> pattern,
    {IrSendInfo? info}) async {
  _validateFrequency(frequency);
  _validatePattern(pattern, where: 'rawPattern');
  final IrSendInfo sendInfo =
      info ?? IrSendInfo(label: 'Raw signal', protocol: 'RAW', source: 'Raw');
  try {
    await platform
        .invokeMethod("transmitRaw", {"frequency": frequency, "list": pattern});
    _logSend(sendInfo, frequency, pattern.length);
  } on PlatformException catch (e) {
    _logSend(sendInfo, frequency, pattern.length, error: e.message ?? e.code);
    rethrow;
  } catch (e, st) {
    _reportFlutterError('transmitRaw()', e, st);
    _logSend(sendInfo, frequency, pattern.length, error: e);
    rethrow;
  }
}

Future<void> transmitRawCycles(int frequency, List<int> pattern,
    {IrSendInfo? info}) async {
  _validateFrequency(frequency);
  _validatePattern(pattern, where: 'rawCycles');
  final IrSendInfo sendInfo = info ??
      IrSendInfo(label: 'Raw signal', protocol: 'RAW (cycles)', source: 'Raw');
  try {
    await platform.invokeMethod(
      "transmitRawCycles",
      {"frequency": frequency, "list": pattern},
    );
    _logSend(sendInfo, frequency, pattern.length);
  } on PlatformException catch (e) {
    _logSend(sendInfo, frequency, pattern.length, error: e.message ?? e.code);
    rethrow;
  } catch (e, st) {
    _reportFlutterError('transmitRawCycles()', e, st);
    _logSend(sendInfo, frequency, pattern.length, error: e);
    rethrow;
  }
}

Future<bool> hasIrEmitter() async {
  try {
    final result = await platform.invokeMethod("hasIrEmitter");
    return result == true;
  } catch (e, st) {
    _reportFlutterError('hasIrEmitter()', e, st);
    return false;
  }
}

List<int> convertNECtoList(int nec) {
  return buildNecPatternFromStoredCodeMSBFirst(nec, params: NECParams.defaults);
}

class IrPreview {
  final int frequencyHz;
  final List<int> pattern;
  final String mode;

  const IrPreview({
    required this.frequencyHz,
    required this.pattern,
    required this.mode,
  });
}

IrPreview previewIRButton(IRButton button) {
  if (button.protocol != null && button.protocol!.trim().isNotEmpty) {
    final id = button.protocol!.trim();
    if (id == IrProtocolIds.tiqiaaLearned ||
        id == IrProtocolIds.elksmartLearned ||
        id == IrProtocolIds.audioLearned) {
      final params = button.protocolParams ?? <String, dynamic>{};
      final rawPreview = (params['rawPreview'] as String? ?? '').trim();
      if (rawPreview.isEmpty) {
        throw StateError('Learned signal is missing raw preview data');
      }
      final pattern = _parseRawPattern(
        rawPreview,
        where: 'learned preview',
      );
      final rawFreq = (params['frequencyHz'] as num?)?.toInt() ?? 0;
      final freq = rawFreq > 0
          ? rawFreq.clamp(kMinIrFrequencyHz, kMaxIrFrequencyHz)
          : 38000;
      _validatePattern(pattern, where: 'previewLearnedSignal');
      return IrPreview(
        frequencyHz: freq,
        pattern: pattern,
        mode: 'protocol:$id',
      );
    }
  }

  final hasRaw = button.rawData != null && button.rawData!.trim().isNotEmpty;
  final hasFreq = button.frequency != null && button.frequency! > 0;

  if (hasRaw && hasFreq) {
    if (isNecConfigString(button.rawData)) {
      if (button.code != null) {
        final params = parseNecParamsFromString(button.rawData!);
        final pattern = _buildCustomNecPattern(
          button.code!,
          bitOrder: button.necBitOrder,
          params: params,
        );
        _validatePattern(pattern, where: 'previewNecCustom');
        _validateFrequency(button.frequency!);
        return IrPreview(
          frequencyHz: button.frequency!,
          pattern: pattern,
          mode: 'legacy_nec_custom',
        );
      }
      throw StateError('Custom NEC timings provided but hex code is missing');
    }

    final pattern = _parseRawPattern(button.rawData!, where: 'raw data');
    _validatePattern(pattern, where: 'previewRaw');
    _validateFrequency(button.frequency!);
    return IrPreview(
      frequencyHz: button.frequency!,
      pattern: pattern,
      mode: 'legacy_raw',
    );
  }

  if (button.protocol != null && button.protocol!.trim().isNotEmpty) {
    final id = button.protocol!.trim();
    final enc = IrProtocolRegistry.encoderFor(id);
    final params = <String, dynamic>{
      ...?button.protocolParams,
      '_preview': true,
    };
    final res = enc.encode(params);
    final int freq = (button.frequency != null && button.frequency! > 0)
        ? button.frequency!
        : res.frequencyHz;
    _validateFrequency(freq);
    _validatePattern(res.pattern, where: 'previewProtocol');
    return IrPreview(
      frequencyHz: freq,
      pattern: res.pattern,
      mode: 'protocol:$id',
    );
  }

  if (button.code != null) {
    final pattern = convertNECtoList(button.code!);
    _validatePattern(pattern, where: 'previewNecDefault');
    return IrPreview(
      frequencyHz: kDefaultNecFrequencyHz,
      pattern: pattern,
      mode: 'legacy_nec_default',
    );
  }

  throw StateError('IRButton has neither raw data nor hex code to preview');
}

Future<void> sendIR(
  IRButton button, {
  bool repeat = false,
  void Function(IrPreview signal)? onEncoded,
  String source = 'Remote',
}) async {
  final IrSendInfo sendInfo = describeIrButton(button, source: source);
  // Observe the actual encoding, rather than encoding again (toggle protocols).
  Future<void> sendRaw(int frequency, List<int> pattern) async {
    _validateFrequency(frequency);
    _validatePattern(pattern, where: 'sendIR');
    onEncoded?.call(IrPreview(
      frequencyHz: frequency,
      pattern: List<int>.unmodifiable(pattern),
      mode: 'transmission',
    ));
    await transmitRaw(frequency, pattern, info: sendInfo);
  }
  if (button.protocol != null && button.protocol!.trim().isNotEmpty) {
    final id = button.protocol!.trim();
    if (id == IrProtocolIds.tiqiaaLearned ||
        id == IrProtocolIds.elksmartLearned ||
        id == IrProtocolIds.audioLearned) {
      final params = button.protocolParams ?? <String, dynamic>{};
      final family = (params['family'] as String? ?? '').trim();
      final rawPreview = (params['rawPreview'] as String? ?? '').trim();
      final isUsbLearned = id == IrProtocolIds.tiqiaaLearned ||
          id == IrProtocolIds.elksmartLearned;
      if (isUsbLearned && rawPreview.isNotEmpty) {
        final rawFreq = (params['frequencyHz'] as num?)?.toInt() ?? 0;
        final freq = rawFreq > 0
            ? rawFreq.clamp(kMinIrFrequencyHz, kMaxIrFrequencyHz)
            : kDefaultNecFrequencyHz;
        await sendRaw(
          freq,
          _parseRawPattern(rawPreview, where: 'learned raw preview'),
        );
        return;
      }
      if (id == IrProtocolIds.tiqiaaLearned) {
        throw StateError('Learned Tiqiaa signal is missing raw replay data');
      }
      final opaqueFrameBase64 =
          (params['opaqueFrameBase64'] as String? ?? '').trim();
      final opaqueMeta = (params['opaqueMeta'] as num?)?.toInt();
      if (family.isEmpty || opaqueFrameBase64.isEmpty) {
        throw StateError('Learned signal is missing replay payload');
      }
      final ok = await IrTransmitterPlatform.replayLearnedUsbSignal(
        family: family,
        opaqueFrameBase64: opaqueFrameBase64,
        opaqueMeta: opaqueMeta,
      );
      recordIrSend(
        label: sendInfo.label,
        protocol: '${sendInfo.protocol} (USB replay)',
        hex: sendInfo.hex,
        frequencyHz: button.frequency ?? 0,
        source: sendInfo.source,
        error: ok ? null : 'LEARNED_REPLAY_FAILED',
      );
      if (!ok) {
        throw PlatformException(
          code: 'LEARNED_REPLAY_FAILED',
          message: 'The learned signal could not be replayed',
        );
      }
      return;
    }
  }

  final hasRaw = button.rawData != null && button.rawData!.trim().isNotEmpty;
  final hasFreq = button.frequency != null && button.frequency! > 0;

  if (hasRaw && hasFreq) {
    if (isNecConfigString(button.rawData)) {
      if (button.code != null) {
        final params = parseNecParamsFromString(button.rawData!);
        final pattern = _buildCustomNecPattern(
          button.code!,
          bitOrder: button.necBitOrder,
          params: params,
        );
        await sendRaw(button.frequency ?? kDefaultNecFrequencyHz, pattern);
        return;
      } else {
        throw StateError('Custom NEC timings provided but hex code is missing');
      }
    }

    final pattern = _parseRawPattern(button.rawData!, where: 'raw data');
    await sendRaw(button.frequency!, pattern);
    return;
  }

  if (button.code != null &&
      (button.protocol == null || button.protocol!.trim().isEmpty)) {
    onEncoded?.call(IrPreview(
      frequencyHz: kDefaultNecFrequencyHz,
      pattern: List<int>.unmodifiable(convertNECtoList(button.code!)),
      mode: 'legacy_nec_default',
    ));
    await transmit(button.code!, info: sendInfo);
    return;
  }

  if (button.protocol != null && button.protocol!.trim().isNotEmpty) {
    final id = button.protocol!.trim();
    final enc = IrProtocolRegistry.encoderFor(id);
    final params = <String, dynamic>{
      ...?button.protocolParams,
      if (repeat) '_repeat': true,
    };
    final res = enc.encode(params);
    final int freq = (button.frequency != null && button.frequency! > 0)
        ? button.frequency!
        : res.frequencyHz;
    await sendRaw(freq, res.pattern);
    return;
  }

  throw StateError('IRButton has neither raw data nor hex code to send');
}
