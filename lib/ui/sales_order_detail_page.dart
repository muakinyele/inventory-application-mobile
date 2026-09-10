import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/invoice.dart';
import '../models/party.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/document_link_row.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/status_pill.dart';

class SalesOrderDetailPage extends StatelessWidget {
  const SalesOrderDetailPage({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final order = controller.salesOrderById(orderId);
    final p = context.palette;

    if (order == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Sale not found',
          body: 'It may have been deleted.',
          action: FilledButton(
            onPressed: () => context.go('/sales-orders'),
            child: const Text('Back to sales'),
          ),
        ),
      );
    }

    final currency = controller.settings.currency;
    final margin = order.marginRate;
    final receipts = controller.receiptsForSalesOrder(order.id);
    final invoices = controller.invoicesForSalesOrder(order.id);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: order.reference,
              subtitle: order.customerName.isEmpty
                  ? 'Walk-in · ${order.priceTier.label} prices'
                  : '${order.customerName} · ${order.priceTier.label} prices',
              showBack: true,
              actions: [
                if (order.status.isEditable)
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.go('/sales-orders/${order.id}/edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                if (order.status == SalesStatus.draft)
                  FilledButton.icon(
                    onPressed: () => controller.confirmSalesOrder(order.id),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Confirm sale'),
                  ),
                if (order.status.isOpen)
                  FilledButton.icon(
                    onPressed: () => _send(context, controller, order),
                    icon: const Icon(Icons.local_shipping_outlined, size: 18),
                    label: const Text('Send'),
                  ),
                // Only once something has actually gone out: a receipt is
                // proof of goods handed over, not of a promise to send them.
                if (order.unitsFulfilled > 0) ...[
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.go('/receipts/new?sale=${order.id}'),
                    icon: const Icon(Icons.receipt_rounded, size: 18),
                    label: const Text('Issue receipt'),
                  ),
                  // The same goods, billed rather than paid for now.
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.go('/invoices/new?sale=${order.id}'),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('Invoice'),
                  ),
                ],
              ],
            ),
            SectionCard(
              child: Wrap(
                spacing: Insets.section,
                runSpacing: Insets.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SalesStatusPill(
                    status: order.status,
                    overdue: order.isOverdue,
                  ),
                  _Fact(
                    label: 'Confirmed',
                    value: order.confirmedAt == null
                        ? '—'
                        : dayLabel(order.confirmedAt!),
                  ),
                  _Fact(
                    label: 'Promised',
                    value: order.dueAt == null ? '—' : dayLabel(order.dueAt!),
                  ),
                  _Fact(
                    label: 'Sent',
                    value:
                        '${number(order.unitsFulfilled)} of '
                        '${number(order.unitsOrdered)}',
                  ),
                  _Fact(label: 'Total', value: money(order.total, currency)),
                ],
              ),
            ),
            if (order.unitsFulfilled > 0) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Margin on what has shipped',
                child: Wrap(
                  spacing: Insets.section,
                  runSpacing: Insets.md,
                  children: [
                    _Fact(
                      label: 'Invoiced',
                      value: money(order.revenue, currency),
                    ),
                    _Fact(
                      label: 'Cost of goods',
                      value: money(order.costOfGoods, currency),
                    ),
                    _Fact(
                      label: 'Gross profit',
                      value: money(order.grossProfit, currency),
                      tone: order.grossProfit < 0 ? p.critical : p.goodText,
                    ),
                    _Fact(
                      label: 'Margin',
                      value: margin == null
                          ? '—'
                          : '${(margin * 100).toStringAsFixed(1)}%',
                      tone: (margin ?? 0) < 0 ? p.critical : p.goodText,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final (index, line) in order.lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineRow(
                      line: line,
                      currency: currency,
                      onHand: controller.byId(line.itemId)?.quantity,
                      showStock: order.status.isOpen,
                    ),
                  ],
                  if (order.lines.isEmpty)
                    Text(
                      'This sale has no lines.',
                      style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                    ),
                ],
              ),
            ),
            if (receipts.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Receipts',
                child: Column(
                  children: [
                    for (final (index, receipt) in receipts.indexed) ...[
                      if (index > 0) Divider(color: p.line, height: Insets.lg),
                      DocumentLinkRow(
                        reference: receipt.reference,
                        detail:
                            '${receipt.method.label} · '
                            '${dateTimeLabel(receipt.issuedAt)}',
                        amount: money(receipt.netTotal, currency),
                        onOpen: () => context.go('/receipts/${receipt.id}'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            // The other half of the paper trail: what was billed on account
            // rather than paid for at the counter.
            if (invoices.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Invoices',
                child: Column(
                  children: [
                    for (final (index, invoice) in invoices.indexed) ...[
                      if (index > 0) Divider(color: p.line, height: Insets.lg),
                      DocumentLinkRow(
                        reference: invoice.reference,
                        detail: [
                          invoice.isOverdue ? 'Overdue' : invoice.status.label,
                          'issued ${dayLabel(invoice.issuedAt)}',
                        ].join(' · '),
                        amount: money(invoice.total, currency),
                        onOpen: () => context.go('/invoices/${invoice.id}'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (order.notes.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Notes',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    order.notes,
                    style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
                  ),
                ),
              ),
            ],
            const SizedBox(height: Insets.xl),
            Row(
              children: [
                if (order.status != SalesStatus.fulfilled &&
                    order.status != SalesStatus.cancelled)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _cancel(context, controller, order),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.critical,
                        side: BorderSide(
                          color: p.critical.withValues(alpha: 0.4),
                        ),
                      ),
                      icon: const Icon(Icons.block_rounded, size: 18),
                      label: const Text('Cancel sale'),
                    ),
                  ),
                if (order.unitsFulfilled == 0) ...[
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _delete(context, controller, order),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.critical,
                        backgroundColor: p.criticalWash,
                        side: BorderSide(
                          color: p.critical.withValues(alpha: 0.4),
                        ),
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(
    BuildContext context,
    InventoryController controller,
    SalesOrder order,
  ) async {
    final sendable = {
      for (final line in order.lines)
        line.id: controller.sendableOn(order, line),
    };
    if (sendable.values.every((q) => q <= 0)) {
      await showAppMessage(
        context,
        'Nothing on the shelf to send against this sale',
        tone: MessageTone.warning,
      );
      return;
    }

    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SendSheet(order: order, sendable: sendable),
    );
    if (result == null || result.isEmpty) return;

    final moved = controller.fulfilSalesOrder(order.id, result);
    if (!context.mounted) return;
    await showAppMessage(
      context,
      moved == 0
          ? 'Nothing to send'
          : 'Sent ${moved == 1 ? '1 line' : '$moved lines'}',
      tone: moved == 0 ? MessageTone.warning : MessageTone.success,
    );
  }

  Future<void> _cancel(
    BuildContext context,
    InventoryController controller,
    SalesOrder order,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel sale'),
        content: Text(
          order.unitsFulfilled > 0
              ? 'Cancel ${order.reference}? Stock already sent stays gone; '
                    'only the outstanding balance is dropped.'
              : 'Cancel ${order.reference}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Cancel sale'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.cancelSalesOrder(order.id);
  }

  Future<void> _delete(
    BuildContext context,
    InventoryController controller,
    SalesOrder order,
  ) async {
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete sale'),
        content: Text(
          'Remove ${order.reference}? Nothing has been sent against it, so '
          'no stock is affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    controller.deleteSalesOrder(order.id);
    router.go('/sales-orders');
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: p.inkMuted)),
        const SizedBox(height: 1),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: tone ?? p.ink,
          ),
        ),
      ],
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.currency,
    required this.onHand,
    required this.showStock,
  });

  final SalesOrderLine line;
  final String currency;
  final int? onHand;
  final bool showStock;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final short = showStock && line.outstanding > (onHand ?? 0);

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                line.itemName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
              Text(
                '${number(line.quantityOrdered)} ordered · '
                '${number(line.quantityFulfilled)} sent'
                '${line.outstanding > 0 ? ' · ${number(line.outstanding)} outstanding' : ''}',
                style: TextStyle(fontSize: 12.5, color: p.inkMuted),
              ),
              if (short)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 13,
                        color: p.warningText,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Only ${number(onHand ?? 0)} on the shelf',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.warningText,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: Insets.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              money(line.lineTotal, currency),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: p.ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '${money(line.unitPrice, currency)} each',
              style: TextStyle(fontSize: 12, color: p.inkMuted),
            ),
          ],
        ),
      ],
    );
  }
}

/// Asks how much of each line is going out, pre-filled with the balance that
/// is actually on the shelf — a sale can never send stock that is not there.
class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.order, required this.sendable});

  final SalesOrder order;
  final Map<String, int> sendable;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final line in widget.order.lines)
      if (line.outstanding > 0)
        line.id: TextEditingController(
          text: '${widget.sendable[line.id] ?? 0}',
        ),
  };

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final outstanding = widget.order.lines
        .where((l) => l.outstanding > 0)
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.xl,
            Insets.xs,
            Insets.xl,
            Insets.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Send ${widget.order.reference}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Enter what is going out. Anything left stays outstanding.',
                style: TextStyle(fontSize: 13, color: p.inkSecondary),
              ),
              const SizedBox(height: Insets.lg),
              for (final line in outstanding) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            line.itemName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: p.ink,
                            ),
                          ),
                          Text(
                            (widget.sendable[line.id] ?? 0) < line.outstanding
                                ? '${number(line.outstanding)} outstanding · '
                                      'only ${number(widget.sendable[line.id] ?? 0)} '
                                      'in stock'
                                : '${number(line.outstanding)} outstanding',
                            style: TextStyle(
                              fontSize: 12.5,
                              color:
                                  (widget.sendable[line.id] ?? 0) <
                                      line.outstanding
                                  ? p.warningText
                                  : p.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _fields[line.id],
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(isDense: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.md),
              ],
              const SizedBox(height: Insets.sm),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop({
                    for (final entry in _fields.entries)
                      entry.key: int.tryParse(entry.value.text.trim()) ?? 0,
                  });
                },
                child: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
