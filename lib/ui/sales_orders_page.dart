import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/sales_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/list_section.dart';
import 'widgets/page_header.dart';
import 'widgets/stat_card.dart';
import 'widgets/status_pill.dart';

/// `null` is the "All" pill.
typedef _StatusFilter = SalesStatus?;

class SalesOrdersPage extends StatefulWidget {
  const SalesOrdersPage({super.key});

  @override
  State<SalesOrdersPage> createState() => _SalesOrdersPageState();
}

class _SalesOrdersPageState extends State<SalesOrdersPage> {
  _StatusFilter _status;

  _SalesOrdersPageState() : _status = null;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    final all = controller.salesOrders;
    final visible = _status == null
        ? all
        : all.where((o) => o.status == _status).toList();

    final open = all.where((o) => o.status.isOpen).toList();
    final late = open.where((o) => o.isOverdue).length;
    final toSend = open.fold(0, (sum, o) => sum + o.unitsOutstanding);
    final booked = open.fold(
      0.0,
      (sum, o) =>
          sum + o.lines.fold(0.0, (s, l) => s + l.outstanding * l.unitPrice),
    );

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Sales Orders',
              subtitle: 'What is sold, and what is still to go out',
              actions: [
                FilledButton.icon(
                  onPressed: () => context.go('/sales-orders/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Sale'),
                ),
              ],
            ),
            if (all.isNotEmpty) ...[
              StatGrid(
                cards: [
                  StatCard(
                    icon: Icons.request_quote_outlined,
                    value: number(open.length),
                    label: 'Open sales',
                  ),
                  StatCard(
                    icon: Icons.local_shipping_outlined,
                    value: number(toSend),
                    label: 'Units to send',
                    tone: StatTone.good,
                  ),
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(booked, currency),
                    label: 'Value to invoice',
                    tone: StatTone.good,
                  ),
                  StatCard(
                    icon: Icons.priority_high_rounded,
                    value: number(late),
                    label: 'Late',
                    tone: late > 0 ? StatTone.critical : StatTone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
            ],
            ListSection<SalesOrder>(
              rows: visible,
              totalRows: all.length,
              unit: 'sales',
              searchHint: 'Search by reference, customer or item',
              // The status pills are the page's, so the cursor rewinds on
              // `filterSignature` when one is tapped.
              filterSignature: _status,
              onClearFilters: () => setState(() => _status = null),
              filters: [
                FilterChips<_StatusFilter>(
                  selected: _status,
                  onSelected: (value) => setState(() => _status = value),
                  options: const [
                    FilterOption(null, 'All'),
                    FilterOption(SalesStatus.draft, 'Draft'),
                    FilterOption(SalesStatus.confirmed, 'Confirmed'),
                    FilterOption(SalesStatus.partial, 'Part sent'),
                    FilterOption(SalesStatus.fulfilled, 'Fulfilled'),
                    FilterOption(SalesStatus.cancelled, 'Cancelled'),
                  ],
                ),
              ],
              matches: (order, query) =>
                  order.reference.toLowerCase().contains(query) ||
                  order.customerName.toLowerCase().contains(query) ||
                  order.status.label.toLowerCase().contains(query) ||
                  order.lines.any(
                    (line) => line.itemName.toLowerCase().contains(query),
                  ),
              emptyState: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No sales yet',
                body:
                    'Raise a sale to record what a customer has bought, '
                    'then send it to take the stock off the shelf.',
                action: FilledButton.icon(
                  onPressed: () => context.go('/sales-orders/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Order'),
                ),
              ),
              nothingMatchesTitle: 'Nothing with that status',
              nothingMatchesBody:
                  'Try another filter, or a different search term.',
              itemBuilder: (context, order) =>
                  _SaleCard(order: order, currency: currency),
            ),
          ],
        ),
      ),
    );
  }
}

class _SaleCard extends StatelessWidget {
  const _SaleCard({required this.order, required this.currency});

  final SalesOrder order;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sent = order.unitsOrdered == 0
        ? 0.0
        : order.unitsFulfilled / order.unitsOrdered;

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
          onTap: () => context.go('/sales-orders/${order.id}'),
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
                    SalesStatusPill(
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
                    order.customerName.isEmpty ? 'Walk-in' : order.customerName,
                    order.lines.length == 1
                        ? '1 line'
                        : '${order.lines.length} lines',
                    if (order.dueAt != null) 'due ${dayLabel(order.dueAt!)}',
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
                                width: constraints.maxWidth * sent,
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
                        '${number(order.unitsFulfilled)} of '
                        '${number(order.unitsOrdered)} sent',
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
