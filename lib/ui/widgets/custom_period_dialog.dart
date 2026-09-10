import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/sales_report.dart';

/// The spans the named periods cannot reach.
///
/// Deliberately short. Daily, Weekly, Monthly and Yearly are on the report
/// itself and step backwards, so "this month" or "last month" is already one
/// tap there; repeating them here would be the same span offered twice. What
/// is left is the rolling windows that no amount of stepping produces.
enum _Preset { last7, last30, thisQuarter }

extension _PresetDetail on _Preset {
  String get label => switch (this) {
    _Preset.last7 => 'Last 7 days',
    _Preset.last30 => 'Last 30 days',
    _Preset.thisQuarter => 'This quarter',
  };

  /// Resolved against [today], inclusive at both ends. Nothing runs past
  /// today: there is no trading in the future to report on.
  (DateTime, DateTime) range(DateTime today) {
    final day = DateTime(today.year, today.month, today.day);
    return switch (this) {
      _Preset.last7 => (day.subtract(const Duration(days: 6)), day),
      _Preset.last30 => (day.subtract(const Duration(days: 29)), day),
      _Preset.thisQuarter => (
        DateTime(day.year, ((day.month - 1) ~/ 3) * 3 + 1),
        day,
      ),
    };
  }
}

/// Asks for a span the named periods cannot express.
///
/// This is the other half of the period control on the report, not a second
/// copy of it: the report picks and steps through named periods, and this
/// picks a rolling window or two arbitrary dates. It stays a modal so the
/// figures it applies to are still on screen behind it.
///
/// Returns the chosen span, or null when dismissed.
Future<DateTimeRange?> showCustomPeriodDialog(
  BuildContext context, {
  DateTimeRange? initial,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => _CustomPeriodDialog(initial: initial),
  );
}

class _CustomPeriodDialog extends StatefulWidget {
  const _CustomPeriodDialog({this.initial});

  final DateTimeRange? initial;

  @override
  State<_CustomPeriodDialog> createState() => _CustomPeriodDialogState();
}

class _CustomPeriodDialogState extends State<_CustomPeriodDialog> {
  static final _long = DateFormat('d MMM yyyy');

  late DateTime _from;
  late DateTime _to;

  /// Highlighted when the dates match it exactly, so reopening the dialog
  /// shows which preset is in force rather than forgetting.
  _Preset? _matched;

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _from = initial?.start ?? _Preset.last30.range(_today).$1;
    _to = initial?.end ?? _today;
    _syncMatched();
  }

  void _syncMatched() {
    _matched = null;
    for (final preset in _Preset.values) {
      final (start, end) = preset.range(_today);
      if (_sameDay(start, _from) && _sameDay(end, _to)) {
        _matched = preset;
        return;
      }
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _apply(_Preset preset) {
    final (start, end) = preset.range(_today);
    setState(() {
      _from = start;
      _to = end;
      _matched = preset;
    });
  }

  Future<void> _pick({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _from : _to,
      firstDate: DateTime(_today.year - 5),
      lastDate: _today,
      helpText: isStart ? 'Period from' : 'Period to',
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _from = picked;
        // Picking a start past the end would invert the range, so the end
        // follows rather than the dialog refusing.
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_to.isBefore(_from)) _from = _to;
      }
      _syncMatched();
    });
  }

  /// Inclusive of both ends, which is how the dates read on screen.
  int get _days => _to.difference(_from).inDays + 1;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final range = ReportRange.between(_from, _to);

    return AlertDialog(
      title: const Text('Custom period'),
      titlePadding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.xl,
        Insets.xl,
        Insets.md,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      // Bounded so the dialog stays a dialog on a wide window and does not
      // stretch across it.
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: [
                  for (final preset in _Preset.values)
                    _PresetChip(
                      label: preset.label,
                      selected: _matched == preset,
                      onTap: () => _apply(preset),
                    ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              Row(
                children: [
                  Expanded(
                    child: _DateField(
                      label: 'From',
                      value: _long.format(_from),
                      onTap: () => _pick(isStart: true),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: _DateField(
                      label: 'To',
                      value: _long.format(_to),
                      onTap: () => _pick(isStart: false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              // What Apply will do, in one line: the span as the report will
              // title it, and how long it runs. Both dates count.
              Row(
                children: [
                  Icon(
                    Icons.event_available_outlined,
                    size: 15,
                    color: p.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      range.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(
                    '${number(_days)} ${_days == 1 ? 'day' : 'days'}',
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.md,
        Insets.md,
        Insets.md,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(DateTimeRange(start: _from, end: _to)),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.accent : p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: 7,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? p.accentInk : p.inkSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16),
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.ink,
          ),
        ),
      ),
    );
  }
}
