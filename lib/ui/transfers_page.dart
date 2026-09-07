import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/transfer.dart';
import '../state/inventory_controller.dart';
import 'widgets/bin_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final p = context.palette;
    final transfers = controller.transfers;
    final byLocation = controller.unitsByLocation;
    final totalUnits = controller.totalUnits;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Transfers',
              subtitle: 'Moving stock between your locations',
              actions: [
                FilledButton.icon(
                  onPressed: () => context.go('/transfers/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Move Stock'),
                ),
              ],
            ),
            if (byLocation.isNotEmpty) ...[
              SectionCard(
                title: 'Where your stock is',
                trailing: Text(
                  '${number(totalUnits)} units',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
                child: Column(
                  children: [
                    // Every bin, not a top few — a partial breakdown of a
                    // total reads as if it accounts for all of it.
                    for (final (index, entry)
                        in byLocation.entries.indexed) ...[
                      if (index > 0) const SizedBox(height: 10),
                      BinBar(
                        location: entry.key,
                        quantity: entry.value,
                        total: totalUnits,
                        trailing:
                            '${number(entry.value)}  ·  '
                            '${(entry.value / totalUnits * 100).round()}%',
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Insets.lg),
            ],
            if (transfers.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.swap_horiz_rounded,
                  title: 'Nothing moved yet',
                  body:
                      'Record a transfer when stock goes from one location to '
                      'another. The total on hand does not change — only where '
                      'it is sitting.',
                  action: FilledButton.icon(
                    onPressed: () => context.go('/transfers/new'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Move Stock'),
                  ),
                ),
              )
            else
              for (final transfer in transfers) ...[
                _TransferCard(transfer: transfer),
                const SizedBox(height: Insets.md),
              ],
          ],
        ),
      ),
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                transfer.reference,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              const SizedBox(width: Insets.md),
              Flexible(child: _Route(transfer: transfer)),
              const Spacer(),
              Text(
                '${number(transfer.units)} units',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              dayLabel(transfer.movedAt),
              transfer.lines.length == 1
                  ? '1 item'
                  : '${transfer.lines.length} items',
              if (transfer.notes.isNotEmpty) transfer.notes,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: p.inkMuted),
          ),
          const SizedBox(height: Insets.md),
          Divider(color: p.line, height: 1),
          const SizedBox(height: Insets.md),
          for (final line in transfer.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      line.itemName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.inkSecondary),
                    ),
                  ),
                  Text(
                    number(line.quantity),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// From → to, as one readable chip rather than two loose labels.
class _Route extends StatelessWidget {
  const _Route({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: p.inkSecondary,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              transfer.fromLocation,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 13,
              color: p.inkMuted,
            ),
          ),
          Flexible(
            child: Text(
              transfer.toLocation,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: p.ink),
            ),
          ),
        ],
      ),
    );
  }
}
