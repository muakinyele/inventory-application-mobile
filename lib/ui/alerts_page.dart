import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/list_section.dart';
import 'widgets/page_header.dart';
import 'widgets/stat_card.dart';
import 'widgets/status_chip.dart';

/// A dedicated view of `controller.needsAttention` — the same rule that drives
/// the dashboard tile and the Items status filter, nothing new.
class AlertsPage extends StatelessWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final p = context.palette;
    final flagged = controller.needsAttention;

    if (flagged.isEmpty) {
      return Scaffold(
        backgroundColor: p.plane,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  Insets.pageNarrow,
                  Insets.xl,
                  Insets.pageNarrow,
                  0,
                ),
                child: PageHeader(
                  title: 'Alerts',
                  subtitle: 'Items that need restocking',
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: p.surfaceSunken,
                            borderRadius: BorderRadius.circular(Radii.card),
                          ),
                          child: Icon(
                            Icons.check_circle_outline,
                            size: 30,
                            color: p.good,
                          ),
                        ),
                        const SizedBox(height: Insets.xl),
                        Text(
                          'All stocked up!',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: p.ink,
                          ),
                        ),
                        const SizedBox(height: Insets.sm),
                        Text(
                          'No items are out of stock or below their reorder '
                          'level.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: p.inkSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final out = flagged.where((i) => i.status == StockStatus.out).toList();
    final low = flagged.where((i) => i.status == StockStatus.low).toList();

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Alerts',
              subtitle: 'Items that need restocking',
              actions: [
                OutlinedButton.icon(
                  onPressed: () => context.go('/items?status=low'),
                  icon: const Icon(Icons.filter_alt_outlined, size: 18),
                  label: const Text('Open in Items'),
                ),
              ],
            ),
            StatGrid(
              cards: [
                StatCard(
                  icon: Icons.highlight_off_rounded,
                  value: number(out.length),
                  label: 'Out of Stock',
                  tone: StatTone.critical,
                ),
                StatCard(
                  icon: Icons.warning_amber_rounded,
                  value: number(low.length),
                  label: 'Low Stock',
                  tone: StatTone.warning,
                ),
              ],
            ),
            const SizedBox(height: Insets.lg),
            ListSection<Item>(
              rows: flagged,
              unit: 'items',
              searchHint: 'Search flagged items by name, SKU or category',
              matches: (item, query) =>
                  item.name.toLowerCase().contains(query) ||
                  item.sku.toLowerCase().contains(query) ||
                  item.barcode.contains(query) ||
                  item.category.toLowerCase().contains(query) ||
                  item.location.toLowerCase().contains(query) ||
                  item.supplier.toLowerCase().contains(query),
              // Unreachable in practice — the page returns the all-clear
              // above when nothing is flagged — but a list widget that cannot
              // say "nothing here" is one refactor away from showing blank.
              emptyState: const EmptyState(
                icon: Icons.check_circle_outline,
                title: 'Nothing needs attention',
                body: 'Every item is above its reorder level.',
              ),
              itemBuilder: (context, item) => _AlertRow(item: item),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = statusStyle(context, item.status);
    final shortfall = item.reorderLevel - item.quantity;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          onTap: () => context.go('/items/${item.id}'),
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Row(
              children: [
                IconTile(
                  icon: style.icon,
                  color: style.color,
                  wash: style.wash,
                  size: 44,
                ),
                const SizedBox(width: Insets.lg),
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
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: p.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (item.sku.isNotEmpty) item.sku,
                          '${number(item.quantity)} ${item.unit} on hand',
                          if (shortfall > 0)
                            '${number(shortfall)} below reorder level',
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.md),
                StatusChip(status: item.status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
