import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/csv_codec.dart';
import '../data/export_service.dart';
import '../models/movement.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/movement_tile.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

enum _Filter { all, stockIn, stockOut, edits }

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key});

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  _Filter _filter = _Filter.all;

  bool _matches(Movement m) => switch (_filter) {
    _Filter.all => true,
    _Filter.stockIn => m.delta > 0,
    _Filter.stockOut => m.delta < 0,
    _Filter.edits => m.delta == 0,
  };

  Future<void> _export(BuildContext buttonContext) async {
    final controller = context.read<InventoryController>();
    if (controller.movements.isEmpty) return;

    await const ExportService().shareText(
      filename: 'stock-movements.csv',
      contents: movementsToCsv(controller.movements),
      mimeType: 'text/csv',
      originRect: shareOriginOf(buttonContext),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Movement history exported')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final p = context.palette;

    var unitsIn = 0;
    var unitsOut = 0;
    for (final m in controller.movements) {
      if (m.delta > 0) unitsIn += m.delta;
      if (m.delta < 0) unitsOut -= m.delta;
    }

    final groups = <String, List<Movement>>{};
    for (final m in controller.movements.where(_matches)) {
      groups.putIfAbsent(dayLabel(m.at), () => []).add(m);
    }

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Activity',
              subtitle:
                  '${number(unitsIn)} units in · ${number(unitsOut)} units out',
              actions: [
                Builder(
                  builder: (buttonContext) => OutlinedButton.icon(
                    onPressed: controller.movements.isEmpty
                        ? null
                        : () => _export(buttonContext),
                    icon: const Icon(Icons.file_download_outlined, size: 18),
                    label: const Text('Export'),
                  ),
                ),
              ],
            ),
            FilterChips<_Filter>(
              selected: _filter,
              onSelected: (value) => setState(() => _filter = value),
              options: const [
                FilterOption(_Filter.all, 'All'),
                FilterOption(
                  _Filter.stockIn,
                  'Stock In',
                  icon: Icons.trending_up_rounded,
                ),
                FilterOption(
                  _Filter.stockOut,
                  'Stock Out',
                  icon: Icons.trending_down_rounded,
                ),
                FilterOption(_Filter.edits, 'Edits', icon: Icons.edit_outlined),
              ],
            ),
            const SizedBox(height: Insets.lg),
            if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.swap_horiz_rounded,
                  title: controller.movements.isEmpty
                      ? 'No movements'
                      : 'Nothing matches that filter',
                  body: controller.movements.isEmpty
                      ? 'Stock changes you record — receipts, sales, '
                            'stocktakes and edits — show up here.'
                      : 'Try another filter to see more of the log.',
                  action: controller.movements.isEmpty
                      ? null
                      : OutlinedButton(
                          onPressed: () =>
                              setState(() => _filter = _Filter.all),
                          child: const Text('Show all'),
                        ),
                ),
              )
            else
              for (final entry in groups.entries) ...[
                SectionCard(
                  title: entry.key,
                  trailing: Text(
                    entry.value.length == 1
                        ? '1 movement'
                        : '${entry.value.length} movements',
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                  child: Column(
                    children: [
                      for (final m in entry.value) ...[
                        if (m != entry.value.first)
                          Divider(color: p.line, height: 1),
                        MovementTile(
                          movement: m,
                          title: m.itemName,
                          subtitle:
                              '${m.note.isEmpty ? 'Updated' : m.note} · ${dateTimeLabel(m.at)}',
                          showBalance: true,
                          onTap: controller.byId(m.itemId) == null
                              ? null
                              : () => context.go('/items/${m.itemId}'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Insets.md),
              ],
          ],
        ),
      ),
    );
  }
}
