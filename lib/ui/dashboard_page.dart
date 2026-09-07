import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../state/inventory_controller.dart';
import 'widgets/charts.dart';
import 'widgets/empty_state.dart';
import 'widgets/movement_tile.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/stat_card.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final settings = controller.settings;
    final currency = settings.currency;
    final p = context.palette;

    final attention = controller.needsAttention;
    final outOfStock = attention
        .where((i) => i.status == StockStatus.out)
        .length;
    final lowStock = attention.length - outOfStock;
    final recent = controller.movements.take(6).toList();

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: controller.items.isEmpty
            ? Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Insets.pageNarrow,
                      Insets.xl,
                      Insets.pageNarrow,
                      0,
                    ),
                    child: PageHeader(
                      title: 'Dashboard',
                      subtitle: longDate(DateTime.now()),
                    ),
                  ),
                  Expanded(
                    child: EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'No stock yet',
                      body:
                          'Add your first item, or load the sample catalogue '
                          'from Settings to see how the app works.',
                      action: FilledButton.icon(
                        onPressed: () => context.go('/items/new'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add item'),
                      ),
                    ),
                  ),
                ],
              )
            : PageBody(
                children: [
                  PageHeader(
                    title: 'Dashboard',
                    subtitle: longDate(DateTime.now()),
                    actions: [
                      OutlinedButton.icon(
                        onPressed: () => context.go('/items?scan=1'),
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
                        label: const Text('Scan'),
                      ),
                      FilledButton.icon(
                        onPressed: () => context.go('/items/new'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add Item'),
                      ),
                    ],
                  ),
                  StatGrid(
                    cards: [
                      StatCard(
                        icon: Icons.inventory_2_outlined,
                        value: number(controller.items.length),
                        label: 'Total Items',
                        onTap: () => context.go('/items'),
                      ),
                      StatCard(
                        icon: Icons.warning_amber_rounded,
                        value: number(lowStock),
                        label: 'Low Stock',
                        tone: StatTone.warning,
                        onTap: () => context.go('/items?status=low'),
                      ),
                      StatCard(
                        icon: Icons.highlight_off_rounded,
                        value: number(outOfStock),
                        label: 'Out of Stock',
                        tone: StatTone.critical,
                        onTap: () => context.go('/items?status=out'),
                      ),
                      StatCard(
                        glyph: currencySymbol(currency),
                        value: moneyCompact(
                          controller.totalStockValue,
                          currency,
                        ),
                        label: 'Total Value',
                        tone: StatTone.good,
                        onTap: () => context.go('/reports'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),

                  // These deliberately cut the data differently from Reports:
                  // health is a status breakdown, and location is a dimension
                  // nothing else charts.
                  _TwoUp(
                    left: SectionCard(
                      title: 'Stock health',
                      trailing: _Caption('${controller.items.length} items'),
                      child: CategoryDonutChart(
                        slices: _healthSlices(controller, p),
                        total: controller.items.length.toDouble(),
                        formatValue: (v) => v.round() == 1
                            ? '1 item'
                            : '${number(v.round())} items',
                        centerLabel: 'Total items',
                      ),
                    ),
                    right: SectionCard(
                      title: 'Value by location',
                      trailing: const _Caption('at cost'),
                      child: CategoryBarChart(
                        slices: _locationSlices(controller, p),
                        formatValue: (v) => money(v, currency),
                      ),
                    ),
                  ),
                  const SizedBox(height: Insets.lg),
                  SectionCard(
                    title: 'Recent Transactions',
                    trailing: _ViewAll(onTap: () => context.go('/activity')),
                    child: recent.isEmpty
                        ? _Placeholder(
                            text:
                                'Stock movements will appear here once you '
                                'record one.',
                          )
                        : Column(
                            children: [
                              for (final m in recent) ...[
                                if (m != recent.first)
                                  Divider(color: p.line, height: 1),
                                MovementTile(
                                  movement: m,
                                  title: m.itemName,
                                  subtitle: dateTimeLabel(m.at),
                                  onTap: controller.byId(m.itemId) == null
                                      ? null
                                      : () => context.go('/items/${m.itemId}'),
                                ),
                              ],
                            ],
                          ),
                  ),
                  if (attention.isNotEmpty) ...[
                    const SizedBox(height: Insets.lg),
                    SectionCard(
                      title: 'Needs Attention',
                      trailing: _ViewAll(onTap: () => context.go('/alerts')),
                      child: Column(
                        children: [
                          for (final item in attention.take(4)) ...[
                            if (item != attention.first)
                              Divider(color: p.line, height: 1),
                            _AttentionRow(item: item),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  /// Item counts by stock state. Status colour is reserved for exactly this,
  /// and each slice is legended by name so the state never rests on hue alone.
  List<ChartSlice> _healthSlices(InventoryController controller, Palette p) {
    var ok = 0;
    var low = 0;
    var out = 0;
    for (final item in controller.items) {
      switch (item.status) {
        case StockStatus.ok:
          ok++;
        case StockStatus.low:
          low++;
        case StockStatus.out:
          out++;
      }
    }
    return [
      if (ok > 0)
        ChartSlice(label: 'In stock', value: ok.toDouble(), color: p.good),
      if (low > 0)
        ChartSlice(label: 'Low stock', value: low.toDouble(), color: p.warning),
      if (out > 0)
        ChartSlice(
          label: 'Out of stock',
          value: out.toDouble(),
          color: p.critical,
        ),
    ];
  }

  /// Where the money is sitting — a magnitude comparison, so one hue.
  ///
  /// Reads the real per-location breakdown, so stock split across two sites
  /// shows up in both rather than all landing on the item's home bin.
  List<ChartSlice> _locationSlices(InventoryController controller, Palette p) {
    final totals = controller.valueByLocation;
    return [
      for (final e in totals.entries.take(5))
        if (e.value > 0)
          ChartSlice(label: e.key, value: e.value, color: p.accent),
    ];
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

class _ViewAll extends StatelessWidget {
  const _ViewAll({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        minimumSize: const Size(0, 32),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('View all'),
          SizedBox(width: 6),
          Icon(Icons.arrow_forward, size: 16),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.md),
      child: Text(
        text,
        style: TextStyle(fontSize: 13.5, color: context.palette.inkMuted),
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isOut = item.status == StockStatus.out;

    return InkWell(
      onTap: () => context.go('/items/${item.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.md),
        child: Row(
          children: [
            IconTile(
              icon: isOut
                  ? Icons.highlight_off_rounded
                  : Icons.warning_amber_rounded,
              color: isOut ? p.critical : p.warningText,
              wash: isOut ? p.criticalWash : p.warningWash,
              size: 36,
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                  Text(
                    isOut
                        ? 'Out of stock'
                        : '${number(item.quantity)} left · reorder at ${number(item.reorderLevel)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: p.inkMuted),
          ],
        ),
      ),
    );
  }
}
