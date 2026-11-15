import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irblaster_controller/l10n/l10n.dart';
import 'package:irblaster_controller/state/signal_log.dart';
import 'package:irblaster_controller/utils/ir_keep_alive.dart';

/// Shows every IR signal the app has transmitted, newest first.
class SignalLogScreen extends StatelessWidget {
  const SignalLogScreen({super.key});

  String _time(DateTime at) {
    final DateTime now = DateTime.now();
    final String clock = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    final bool sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    if (sameDay) return clock;
    final String date = '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
    return '$date $clock';
  }

  String _asText(BuildContext context, List<SignalLogEntry> entries) {
    final StringBuffer buffer = StringBuffer();
    for (final SignalLogEntry e in entries) {
      buffer.writeln('[${_time(e.at)}] ${e.label}');
      buffer.writeln('  ${context.l10n.signalLogFieldProtocol}: ${e.protocol}');
      buffer.writeln('  ${context.l10n.signalLogFieldHex}: ${e.hex}');
      buffer.writeln(
          '  ${context.l10n.signalLogFieldFrequency}: ${e.frequencyHz} Hz');
      buffer.writeln('  ${context.l10n.signalLogFieldSource}: ${e.source}'
          ' (${e.patternLength})');
      if (e.failed) buffer.writeln('  ${context.l10n.signalLogFailed}: ${e.error}');
    }
    return buffer.toString();
  }

  Future<void> _copy(BuildContext context, List<SignalLogEntry> entries) async {
    await Clipboard.setData(ClipboardData(text: _asText(context, entries)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.signalLogCopied)),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.signalLogClearTitle),
        content: Text(dialogContext.l10n.signalLogClearBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.clearAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SignalLog.instance.clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.signalLogClearDone)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: SignalLog.instance,
      builder: (context, _) {
        final List<SignalLogEntry> entries = SignalLog.instance.entries;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(context.l10n.signalLogTitle),
                Text(
                  context.l10n.signalLogEntryCount(entries.length),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: context.l10n.signalLogCopyTooltip,
                icon: const Icon(Icons.copy_all_outlined),
                onPressed:
                    entries.isEmpty ? null : () => _copy(context, entries),
              ),
              IconButton(
                tooltip: context.l10n.clearAction,
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed:
                    entries.isEmpty ? null : () => _confirmClear(context),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              const _SurvivalBanner(),
              Expanded(
                child: entries.isEmpty
                    ? _EmptyState()
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => _LogCard(
                          entry: entries[index],
                          timeLabel: _time(entries[index].at),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Explains (and fixes) the one thing that really stops a long test on MIUI:
/// the app being excluded from battery optimization. Also shows the survival
/// counters so "the service kept sending" is provable, not a claim.
class _SurvivalBanner extends StatefulWidget {
  const _SurvivalBanner();

  @override
  State<_SurvivalBanner> createState() => _SurvivalBannerState();
}

class _SurvivalBannerState extends State<_SurvivalBanner> {
  bool _allowed = true;
  bool _loaded = false;
  int _nativeSends = 0;
  int _revives = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final List<dynamic> results = await Future.wait(<Future<dynamic>>[
      IrKeepAlive.isIgnoringBatteryOptimizations,
      IrKeepAlive.guardState(),
    ]);
    if (!mounted) return;
    final Map<String, dynamic> state =
        (results[1] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    setState(() {
      _allowed = results[0] as bool? ?? true;
      _nativeSends = state['nativeSends'] is int ? state['nativeSends'] as int : 0;
      _revives = state['revives'] is int ? state['revives'] as int : 0;
      _loaded = true;
    });
  }

  Future<void> _openSettings() async {
    await IrKeepAlive.requestIgnoreBatteryOptimizations();
    // Give the user a moment in the system screen, then re-read the state.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool warn = !_allowed;
    final Color tint = warn ? cs.errorContainer : cs.surfaceContainerHighest;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                warn ? Icons.battery_alert_outlined : Icons.shield_outlined,
                size: 18,
                color: warn ? cs.error : cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warn
                      ? context.l10n.signalLogBatteryTitle
                      : context.l10n.signalLogBatteryOk,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            warn
                ? context.l10n.signalLogBatteryBody
                : context.l10n.signalLogSurvivalNote,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (_nativeSends > 0 || _revives > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              <String>[
                if (_nativeSends > 0)
                  context.l10n.signalLogNativeSends(_nativeSends),
                if (_revives > 0) context.l10n.signalLogRevives(_revives),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
          if (warn) ...<Widget>[
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(context.l10n.signalLogBatteryAction),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.receipt_long_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.signalLogEmptyTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.signalLogEmptyBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entry, required this.timeLabel});

  final SignalLogEntry entry;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color accent = entry.failed ? cs.error : cs.primary;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.settings_remote, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.label,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  timeLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _FieldRow(label: context.l10n.signalLogFieldProtocol, value: entry.protocol),
            _FieldRow(
              label: context.l10n.signalLogFieldHex,
              value: entry.hex,
              monospace: true,
            ),
            _FieldRow(
              label: context.l10n.signalLogFieldFrequency,
              value: entry.frequencyHz > 0 ? '${entry.frequencyHz} Hz' : '—',
            ),
            _FieldRow(
              label: context.l10n.signalLogFieldSource,
              value: '${entry.source} · ${entry.patternLength}',
            ),
            if (entry.failed) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '${context.l10n.signalLogFailed}: ${entry.error}',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
