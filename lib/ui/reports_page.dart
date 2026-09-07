import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/app_settings.dart';
import '../models/item.dart';
import '../state/inventory_controller.dart';
import 'widgets/charts.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/stat_card.dart';

/// A read-only view over figures the controller already derives — no new data
/// and no new business rules, only different ways of reading the same numbers.
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  /// Six is the honest ceiling for a donut; past that the tail folds into one
  /// "Other" slice rather than sprouting more colours.
  static const _maxSlices = 6;

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

    String asMoney(double v) => money(v, currency);
    String asUnits(double v) => '${number(v.round())} units';

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            const PageHeader(
              title: 'Reports',
              subtitle: 'Where your stock and its value actually sit',
            ),
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
            const SizedBox(height: Insets.lg),

            // Magnitude and share answer different questions, so they sit side
            // by side: the bars for "which is biggest", the donut for "how much
            // of the whole" — a donut alone cannot be read for close values.
            _TwoUp(
              left: SectionCard(
                title: 'Stock value by category',
                trailing: const _Caption('at cost'),
                child: CategoryBarChart(
                  slices: valueSlices,
                  formatValue: asMoney,
                ),
              ),
              right: SectionCard(
                title: 'Share of stock value',
                trailing: const _Caption('% of total'),
                child: CategoryDonutChart(
                  slices: valueSlices,
                  total: controller.totalStockValue,
                  formatValue: asMoney,
                  centerLabel: 'Total value',
                ),
              ),
            ),
            const SizedBox(height: Insets.lg),

            SectionCard(
              title: 'Stock movement — last 14 days',
              trailing: const _Caption('units in and out'),
              child: FlowChart(days: flow),
            ),
            const SizedBox(height: Insets.lg),

            _TwoUp(
              left: SectionCard(
                title: 'Units held by category',
                trailing: const _Caption('count'),
                child: CategoryDonutChart(
                  slices: unitSlices,
                  total: controller.totalUnits.toDouble(),
                  formatValue: asUnits,
                  centerLabel: 'Units on hand',
                ),
              ),
              right: SectionCard(
                title: 'Top items by stock value',
                child: _TopItems(controller: controller, currency: currency),
              ),
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
