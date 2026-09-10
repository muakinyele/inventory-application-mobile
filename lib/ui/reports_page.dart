import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import '../data/report_document.dart';
import '../data/sales_report.dart';
import '../models/app_settings.dart';
import '../models/item.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/charts.dart';
import 'widgets/custom_period_dialog.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/stat_card.dart';
import 'widgets/trading_report.dart';

/// Two reports on one page, and they answer different questions.
///
/// **Trading** is what the business earned over a period: revenue, what those
/// goods cost, and the profit between them, per item and in total. It is
/// bounded by a date range and exports to PDF and Excel.
///
/// **Stock** is a snapshot of what is on the shelf right now, at cost. It has
/// no period — it is a photograph, not a film — which is why the two sit in
/// separate sections rather than under one set of filters.
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  /// Six is the honest ceiling for a donut; past that the tail folds into one
  /// "Other" slice rather than sprouting more colours.
  static const _maxSlices = 6;

  ReportPeriod _period = ReportPeriod.monthly;

  /// The day the current period is resolved around. Stepping moves this.
  DateTime _anchor = DateTime.now();

  /// Set only while [_period] is custom.
  DateTimeRange? _customRange;

  /// Which measure the category breakdown is cut by: stock value, or units.
  bool _byValue = true;

  bool _exporting = false;

  ReportRange get _range {
    if (_period == ReportPeriod.custom) {
      final custom = _customRange;
      if (custom == null) return ReportRange.of(ReportPeriod.monthly, _anchor);
      return ReportRange.between(custom.start, custom.end);
    }
    return ReportRange.of(_period, _anchor);
  }

  /// A period that already covers today has nothing beyond it to show.
  bool get _canStepForward => _range.end.isBefore(DateTime.now());

  void _step(int direction) {
    setState(() {
      _anchor = switch (_period) {
        ReportPeriod.daily => _anchor.add(Duration(days: direction)),
        ReportPeriod.weekly => _anchor.add(Duration(days: 7 * direction)),
        // Day 1 avoids the 31st-of-January problem, where adding a month
        // lands on the wrong side of a short February.
        ReportPeriod.monthly => DateTime(
          _anchor.year,
          _anchor.month + direction,
        ),
        ReportPeriod.yearly => DateTime(_anchor.year + direction),
        ReportPeriod.custom => _anchor,
      };
    });
  }

  Future<void> _pickCustom() async {
    final picked = await showCustomPeriodDialog(context, initial: _customRange);
    if (picked != null) setState(() => _customRange = picked);
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  Future<void> _export(
    Rect? origin,
    SalesReport report,
    AppSettings settings, {
    required bool asPdf,
  }) async {
    final doc = ReportDocument(report, settings);
    setState(() => _exporting = true);
    try {
      if (asPdf) {
        await const ExportService().shareBytes(
          filename: doc.filename('pdf'),
          bytes: await doc.toPdf(),
          mimeType: 'application/pdf',
          originRect: origin,
        );
      } else {
        await const ExportService().shareBytes(
          filename: doc.filename('xlsx'),
          bytes: doc.toXlsx(),
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          originRect: origin,
        );
      }
    } catch (error) {
      if (mounted) {
        _notify(
          'That file could not be produced: $error',
          tone: MessageTone.failure,
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (mounted) {
      _notify('${asPdf ? 'PDF' : 'Excel'} report exported');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final settings = controller.settings;
    final currency = settings.currency;
    final p = context.palette;

    if (controller.items.isEmpty) {
      return Scaffold(
        backgroundColor: p.plane,
        body: const SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  Insets.pageNarrow,
                  Insets.xl,
                  Insets.pageNarrow,
                  0,
                ),
                child: PageHeader(title: 'Reports'),
              ),
              Expanded(
                child: EmptyState(
                  icon: Icons.bar_chart_rounded,
                  title: 'Nothing to report yet',
                  body:
                      'Add items and record some stock movements, and the '
                      'breakdowns will appear here.',
                ),
              ),
            ],
          ),
        ),
      );
    }

    final valueSlices = _slices(
      controller.items,
      settings,
      p,
      measure: (item) => item.stockValue,
    );
    final unitSlices = _slices(
      controller.items,
      settings,
      p,
      measure: (item) => item.quantity.toDouble(),
    );
    final flow = _flow(controller);
    final report = SalesReport.build(
      range: _range,
      receipts: controller.receipts,
      invoices: controller.invoices,
      salesOrders: controller.salesOrders,
      currency: currency,
    );

    String asMoney(double v) => money(v, currency);
    String asUnits(double v) => '${number(v.round())} units';

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Reports',
              subtitle: 'What you earned, and where your stock sits',
              actions: [
                Builder(
                  builder: (buttonContext) => FilledButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _export(
                            shareOriginOf(buttonContext),
                            report,
                            settings,
                            asPdf: true,
                          ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('PDF'),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => OutlinedButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _export(
                            shareOriginOf(buttonContext),
                            report,
                            settings,
                            asPdf: false,
                          ),
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Text('Excel'),
                  ),
                ),
              ],
            ),

            // --- Trading ----------------------------------------------------
            // Everything under this heading is bounded by the period bar, and
            // each figure appears in exactly one place: the four totals, where
            // the revenue came from, then the per-item detail those add up to.
            _SectionHeading(
              title: 'Trading',
              note:
                  'What was earned over the period, and what those goods cost.',
              trailing:
                  '${number(report.documentCount)} '
                  '${report.documentCount == 1 ? 'sale' : 'sales'}',
            ),
            const SizedBox(height: Insets.md),
            SectionCard(
              padding: const EdgeInsets.all(Insets.md),
              child: PeriodPicker(
                period: _period,
                range: _range,
                canStepForward: _canStepForward,
                onPeriodChanged: (value) => setState(() {
                  _period = value;
                  if (value == ReportPeriod.custom && _customRange == null) {
                    // Opening Custom with nothing chosen would show a range
                    // the user never picked, so it asks straight away.
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _pickCustom(),
                    );
                  }
                }),
                onStep: _step,
                onPickCustom: _pickCustom,
              ),
            ),
            const SizedBox(height: Insets.md),
            TradingSummary(report: report),
            const SizedBox(height: Insets.md),
            SectionCard(
              title: 'Revenue by source',
              trailing: const _Caption('before tax'),
              child: RevenueSources(report: report),
            ),
            const SizedBox(height: Insets.md),
            // The full ranking, best earner first — which is also the answer
            // to "what sold well", so there is no separate top-sellers card
            // repeating the head of this list.
            SectionCard(
              title: 'Profit by item',
              trailing: const _Caption('best earners first'),
              child: TradingTable(report: report),
            ),
            const SizedBox(height: Insets.section),

            // --- Stock on hand ----------------------------------------------
            _SectionHeading(
              title: 'Stock on hand',
              note:
                  'A snapshot of the shelf as it is now, at cost. The period '
                  'above does not bound it.',
            ),
            const SizedBox(height: Insets.md),
            StatGrid(
              cards: [
                StatCard(
                  icon: Icons.inventory_2_outlined,
                  value: number(controller.items.length),
                  label: 'Total Items',
                ),
                StatCard(
                  icon: Icons.trending_up_rounded,
                  value: number(controller.totalUnits),
                  label: 'Total Stock',
                  tone: StatTone.good,
                ),
                StatCard(
                  glyph: currencySymbol(currency),
                  value: moneyCompact(controller.totalStockValue, currency),
                  label: 'Inventory Value',
                  tone: StatTone.good,
                ),
                StatCard(
                  icon: Icons.warning_amber_rounded,
                  value: number(controller.needsAttention.length),
                  label: 'Needs Reorder',
                  tone: StatTone.warning,
                ),
              ],
            ),
            const SizedBox(height: Insets.md),

            // One breakdown by category, not three. Value and units are two
            // measures of the same cut, so they share a card and a switch;
            // the ring carries the share and the legend the exact figures,
            // which is what the separate bar chart beside it used to say.
            _TwoUp(
              left: SectionCard(
                title: 'Stock by category',
                trailing: _MeasureToggle(
                  byValue: _byValue,
                  onChanged: (value) => setState(() => _byValue = value),
                ),
                child: CategoryDonutChart(
                  slices: _byValue ? valueSlices : unitSlices,
                  total: _byValue
                      ? controller.totalStockValue
                      : controller.totalUnits.toDouble(),
                  formatValue: _byValue ? asMoney : asUnits,
                  centerLabel: _byValue ? 'Total value' : 'Units on hand',
                ),
              ),
              right: SectionCard(
                title: 'Top items by stock value',
                trailing: const _Caption('at cost'),
                child: _TopItems(controller: controller, currency: currency),
              ),
            ),
            const SizedBox(height: Insets.md),
            SectionCard(
              title: 'Stock movement',
              trailing: const _Caption('last 14 days'),
              child: FlowChart(days: flow),
            ),
          ],
        ),
      ),
    );
  }

  /// Groups items by category, ranks them, and folds the tail into "Other" so
  /// no chart carries more colour classes than a reader can tell apart.
  List<ChartSlice> _slices(
    List<Item> items,
    AppSettings settings,
    Palette p, {
    required double Function(Item) measure,
  }) {
    const uncategorised = 'Uncategorised';
    final totals = <String, double>{};
    for (final item in items) {
      final label = item.category.isEmpty ? uncategorised : item.category;
      totals[label] = (totals[label] ?? 0) + measure(item);
    }
    totals.removeWhere((_, value) => value <= 0);

    final ranked = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (ranked.length <= _maxSlices) {
      return [
        for (final e in ranked)
          ChartSlice(
            label: e.key,
            value: e.value,
            color: e.key == uncategorised
                ? p.inkMuted
                : settings.colorFor(e.key),
          ),
      ];
    }

    final head = ranked.take(_maxSlices - 1);
    final tail = ranked.skip(_maxSlices - 1);
    return [
      for (final e in head)
        ChartSlice(
          label: e.key,
          value: e.value,
          color: e.key == uncategorised ? p.inkMuted : settings.colorFor(e.key),
        ),
      ChartSlice(
        label: 'Other (${tail.length})',
        value: tail.fold<double>(0, (sum, e) => sum + e.value),
        color: p.inkMuted,
      ),
    ];
  }

  /// Units in and out per day for the last two weeks, read straight from the
  /// movement ledger.
  List<DayFlow> _flow(InventoryController controller) {
    final today = DateTime.now();
    final start = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 13));

    final inByDay = <DateTime, int>{};
    final outByDay = <DateTime, int>{};
    for (final m in controller.movements) {
      final day = DateTime(m.at.year, m.at.month, m.at.day);
      if (day.isBefore(start)) continue;
      if (m.delta > 0) {
        inByDay[day] = (inByDay[day] ?? 0) + m.delta;
      } else if (m.delta < 0) {
        outByDay[day] = (outByDay[day] ?? 0) - m.delta;
      }
    }

    return List.generate(14, (i) {
      final day = start.add(Duration(days: i));
      return DayFlow(
        day: day,
        stockIn: inByDay[day] ?? 0,
        stockOut: outByDay[day] ?? 0,
      );
    });
  }
}

/// Side by side when there is room, stacked when there is not.
class _TwoUp extends StatelessWidget {
  const _TwoUp({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 860) {
          return Column(
            children: [
              left,
              const SizedBox(height: Insets.md),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: Insets.md),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.right,
      style: TextStyle(fontSize: 12, color: context.palette.inkMuted),
    );
  }
}

class _TopItems extends StatelessWidget {
  const _TopItems({required this.controller, required this.currency});

  final InventoryController controller;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final items = [...controller.items]
      ..sort((a, b) => b.stockValue.compareTo(a.stockValue));
    final top = items.take(6).toList();
    final leader = top.isEmpty ? 0.0 : top.first.stockValue;

    return Column(
      children: [
        for (final item in top) ...[
          if (item != top.first) const SizedBox(height: Insets.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(
                    money(item.stockValue, currency),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              // A ranked list reads faster with a magnitude cue than with
              // numbers alone.
              LayoutBuilder(
                builder: (context, constraints) {
                  final fraction = leader <= 0
                      ? 0.0
                      : (item.stockValue / leader).clamp(0.02, 1.0);
                  return Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: p.surfaceSunken,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: constraints.maxWidth * fraction,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The label that opens a run of related cards.
///
/// The two halves of this page answer different questions — one is bounded by
/// a period, the other is a snapshot — so each gets the same shaped heading
/// rather than one being a card title and the other a bare line of text.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.note,
    this.trailing,
  });

  final String title;
  final String note;

  /// A short count or qualifier, right-aligned against the title.
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Insets.sm),
              _Caption(trailing!),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(note, style: TextStyle(fontSize: 13, color: p.inkMuted)),
      ],
    );
  }
}

/// Switches the category breakdown between money and units. Two segments, in
/// the card's own header, so the measure is chosen where it is read.
class _MeasureToggle extends StatelessWidget {
  const _MeasureToggle({required this.byValue, required this.onChanged});

  final bool byValue;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    Widget segment(String label, bool value) {
      final selected = value == byValue;
      return Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? p.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            onTap: selected ? null : () => onChanged(value),
            borderRadius: BorderRadius.circular(Radii.pill),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: 5,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? p.ink : p.inkMuted,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // A card header gives its trailing slot a share of the row, not whatever
    // it asks for, so the switch scales down on a narrow card rather than
    // overflowing it.
    return Align(
      alignment: Alignment.centerRight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: p.surfaceSunken,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [segment('Value', true), segment('Units', false)],
          ),
        ),
      ),
    );
  }
}
