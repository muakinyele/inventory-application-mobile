import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/purchase_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/page_header.dart';
import 'widgets/stat_card.dart';
import 'widgets/status_pill.dart';

/// `null` is the "All" pill.
typedef _StatusFilter = PurchaseStatus?;

class PurchaseOrdersPage extends StatefulWidget {
  const PurchaseOrdersPage({super.key});

  @override
  State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  _StatusFilter _status;

  _PurchaseOrdersPageState() : _status = null;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    final all = controller.purchaseOrders;
    final visible = _status == null
        ? all
        : all.where((o) => o.status == _status).toList();

    final open = all.where((o) => o.status.isOpen).toList();
    final overdue = open.where((o) => o.isOverdue).length;
    final onOrder = open.fold(0, (sum, o) => sum + o.unitsOutstanding);
    final committed = open.fold(
      0.0,
      (sum, o) =>
          sum + o.lines.fold(0.0, (s, l) => s + l.outstanding * l.unitCost),
    );

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Purchase Orders',
              subtitle: 'What you have on order, and what is still to arrive',
              actions: [
                FilledButton.icon(
                  onPressed: () => context.go('/purchase-orders/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Order'),
                ),
              ],
            ),
            if (all.isNotEmpty) ...[
              StatGrid(
                cards: [
                  StatCard(
                    icon: Icons.receipt_long_outlined,
                    value: number(open.length),
                    label: 'Open orders',
                  ),
                  StatCard(
                    icon: Icons.inventory_2_outlined,
                    value: number(onOrder),
                    label: 'Units on order',
                    tone: StatTone.good,
                  ),
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(committed, currency),
                    label: 'Committed spend',
                    tone: StatTone.good,
                  ),
                  StatCard(
                    icon: Icons.priority_high_rounded,
                    value: number(overdue),
                    label: 'Overdue',
                    tone: overdue > 0 ? StatTone.critical : StatTone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              FilterChips<_StatusFilter>(
                selected: _status,
                onSelected: (value) => setState(() => _status = value),
                options: const [
                  FilterOption(null, 'All'),
                  FilterOption(PurchaseStatus.draft, 'Draft'),
                  FilterOption(PurchaseStatus.ordered, 'Ordered'),
                  FilterOption(PurchaseStatus.partial, 'Part received'),
                  FilterOption(PurchaseStatus.received, 'Received'),
                  FilterOption(PurchaseStatus.cancelled, 'Cancelled'),
                ],
              ),
              const SizedBox(height: Insets.lg),
            ],
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: all.isEmpty
                      ? 'No purchase orders yet'
                      : 'Nothing with that status',
                  body: all.isEmpty
                      ? 'Raise an order to record what you have bought, then '
                            'receive it to book the stock in.'
                      : 'Try another filter to see more orders.',
                  action: all.isEmpty
                      ? FilledButton.icon(
                          onPressed: () => context.go('/purchase-orders/new'),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('New Order'),
                        )
                      : OutlinedButton(
                          onPressed: () => setState(() => _status = null),
                          child: const Text('Show all'),
                        ),
                ),
              )
            else
              for (final order in visible) ...[
                _OrderCard(order: order, currency: currency),
                const SizedBox(height: Insets.md),
              ],
          ],
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.currency});

  final PurchaseOrder order;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final received = order.unitsOrdered == 0
        ? 0.0
        : order.unitsReceived / order.unitsOrdered;

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
          onTap: () => context.go('/purchase-orders/${order.id}'),
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      order.reference,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    PurchaseStatusPill(
                      status: order.status,
                      overdue: order.isOverdue,
                    ),
                    const Spacer(),
                    Text(
                      money(order.total, currency),
                      style: TextStyle(
                        fontSize: 15,
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
                    order.supplierName.isEmpty
                        ? 'No supplier'
                        : order.supplierName,
                    order.lines.length == 1
                        ? '1 line'
                        : '${order.lines.length} lines',
                    if (order.expectedAt != null)
                      'expected ${dayLabel(order.expectedAt!)}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.inkMuted),
                ),
                if (order.status.isOpen) ...[
                  const SizedBox(height: Insets.md),
                  Row(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: p.surfaceSunken,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: constraints.maxWidth * received,
                                decoration: BoxDecoration(
                                  color: p.good,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      Text(
                        '${number(order.unitsReceived)} of '
                        '${number(order.unitsOrdered)} received',
                        style: TextStyle(fontSize: 12, color: p.inkMuted),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
