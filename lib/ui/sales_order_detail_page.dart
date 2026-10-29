import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/invoice.dart';
import '../models/movement.dart';
import '../models/party.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../data/export_service.dart';
import '../data/sales_order_document.dart';
import '../state/auth_controller.dart';
import '../state/inventory_controller.dart';
import 'document_view_page.dart';
import 'widgets/app_message.dart';
import 'widgets/document_share_sheet.dart';
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
    final leftToBill = {
      for (final (line, left) in controller.leftToBillOn(order)) line.id: left,
    };
    final taken = controller.stockTakenBySale(order.id);

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
                    onPressed: () async {
                      final refused = await controller.confirmSalesOrder(
                        order.id,
                      );
                      if (refused != null) controller.clearWriteError();
                      if (refused != null && context.mounted) {
                        await showAppMessage(
                          context,
                          refused,
                          tone: MessageTone.failure,
                        );
                      }
                    },
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Confirm sale'),
                  ),
                // The order as the document a customer is sent, the same way
                // an invoice offers it: on screen, as a file, or onward.
                OutlinedButton.icon(
                  onPressed: () => context.go('/sales-orders/${order.id}/view'),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View'),
                ),
                _DownloadButton(order: order),
                // "Share", not "Send": on this page sending already means
                // putting the goods on a van.
                OutlinedButton.icon(
                  onPressed: () => _share(context, controller, order),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Share'),
                ),
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
            const SizedBox(height: Insets.lg),
            _PaymentCard(order: order),
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
                      showStock: order.status != SalesStatus.cancelled,
                      leftToBill: leftToBill[line.id] ?? 0,
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
            if (taken.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Stock taken by this sale',
                child: Column(
                  children: [
                    for (final (index, m) in taken.indexed) ...[
                      if (index > 0) Divider(color: p.line, height: Insets.lg),
                      _TakenRow(movement: m),
                    ],
                  ],
                ),
              ),
            ],
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
            if (order.status == SalesStatus.cancelled &&
                controller.liveInvoicesForSalesOrder(order.id).isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              _LiveInvoiceNotice(
                order: order,
                invoices: controller.liveInvoicesForSalesOrder(order.id),
                canRepair:
                    context.watch<AuthController?>()?.can('settings.manage') ??
                    false,
              ),
            ],
            const SizedBox(height: Insets.xl),
            Row(
              children: [
                if (order.status != SalesStatus.cancelled)
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
              ],
            ),
          ],
        ),
      ),
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
              ? 'Cancel ${order.reference}? The ${order.unitsFulfilled} '
                    '${order.unitsFulfilled == 1 ? 'unit' : 'units'} already '
                    'sent go back into stock, and its unpaid invoices and '
                    'receipts are cancelled too.'
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
    if (confirmed != true) return;

    // Awaited: the server returns the stock and can refuse, for instance when
    // the sale has been paid for.
    final refused = await controller.cancelSalesOrder(order.id);
    // Reported below with its reason; nothing on screen was left unsaved.
    if (refused != null) controller.clearWriteError();
    if (!context.mounted) return;
    await showAppMessage(
      context,
      refused ??
          (order.unitsFulfilled > 0
              ? '${order.reference} cancelled and its stock put back'
              : '${order.reference} cancelled'),
      tone: refused == null ? MessageTone.success : MessageTone.failure,
    );
  }
}

/// A cancelled sale with an invoice still live: cancelled before cancelling
/// did this itself. Each invoice can be cancelled from its own page; an
/// administrator can finish the whole sale here.
class _LiveInvoiceNotice extends StatefulWidget {
  const _LiveInvoiceNotice({
    required this.order,
    required this.invoices,
    required this.canRepair,
  });

  final SalesOrder order;
  final List<Invoice> invoices;
  final bool canRepair;

  @override
  State<_LiveInvoiceNotice> createState() => _LiveInvoiceNoticeState();
}

class _LiveInvoiceNoticeState extends State<_LiveInvoiceNotice> {
  bool _busy = false;

  Future<void> _finish() async {
    setState(() => _busy = true);
    final refused = await context
        .read<InventoryController>()
        .repairCancelledSale(widget.order.id);
    if (!mounted) return;
    setState(() => _busy = false);
    await showAppMessage(
      context,
      refused ?? '${widget.order.reference} finished cancelling',
      tone: refused == null ? MessageTone.success : MessageTone.failure,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final paid = widget.invoices.any((i) => i.amountPaid > 0);
    final refs = widget.invoices.map((i) => i.reference).join(', ');

    return SectionCard(
      title: 'Invoice still live',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paid
                ? 'This sale was cancelled but $refs has a payment against '
                      'it. Refund the payment, then cancel the invoice.'
                : 'This sale was cancelled but $refs was not. Open the '
                      'invoice to cancel it; any stock still out comes back '
                      'with it.',
            style: TextStyle(fontSize: 13.5, color: p.warningText),
          ),
          if (widget.canRepair && !paid) ...[
            const SizedBox(height: Insets.md),
            OutlinedButton.icon(
              onPressed: _busy ? null : _finish,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.build_outlined, size: 18),
              label: const Text('Finish cancelling'),
            ),
          ],
        ],
      ),
    );
  }
}

/// How the customer pays, said in their terms rather than the documents'.
///
/// A sales order is only an order: it holds no money and moves no stock.
/// Billing it is what delivers it, so either choice takes the goods off the
/// shelf as it is issued. Paying now is a receipt; paying later is an
/// invoice, with each payment against it becoming a receipt. The two buttons
/// used to be "Issue receipt" and "Invoice" in the header, which named the
/// paperwork and left the user to work out which one meant "they are paying
/// me today". This names the choice, says what each does, and shows where the
/// money stands.
class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.order});

  final SalesOrder order;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final money_ = controller.paymentsForSalesOrder(order.id);
    final cancelled = order.status == SalesStatus.cancelled;
    final draft = order.status == SalesStatus.draft;
    final leftToBill = controller.receiptLinesForSalesOrder(order).isNotEmpty;
    final collectable = money_.collectable;

    return SectionCard(
      title: 'Payment',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Insets.section,
            runSpacing: Insets.md,
            children: [
              _Fact(
                label: 'Paid',
                value: money(money_.paid, currency),
                tone: money_.paid > 0 ? p.goodText : null,
              ),
              _Fact(
                label: 'Owed',
                value: money(money_.owed, currency),
                tone: money_.owed > 0 ? p.warningText : null,
              ),
              _Fact(
                label: 'Not yet billed',
                value: money(money_.unbilled, currency),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          if (cancelled)
            Text(
              'This sale was cancelled, so no payment is taken on it.',
              style: TextStyle(fontSize: 13, color: p.inkMuted),
            )
          else if (draft)
            Text(
              'Confirm the sale first, then choose how the customer pays. '
              'Stock leaves the shelf when the receipt or invoice is issued.',
              style: TextStyle(fontSize: 13, color: p.inkMuted),
            )
          else if (!leftToBill)
            Text(
              'Everything on this order is on a receipt or an invoice.',
              style: TextStyle(fontSize: 13, color: p.inkMuted),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final choices = [
                  _PayChoice(
                    icon: Icons.payments_outlined,
                    title: 'Paid now',
                    body:
                        'The customer pays today. Issues a receipt and takes '
                        'the goods off the shelf.',
                    action: 'Issue receipt',
                    onTap: () => context.go('/receipts/new?sale=${order.id}'),
                  ),
                  _PayChoice(
                    icon: Icons.schedule_outlined,
                    title: 'Pay later',
                    body:
                        'The customer pays on account. Issues an invoice and '
                        'takes the goods off the shelf; record payments as '
                        'they come in.',
                    action: 'Create invoice',
                    onTap: () => context.go('/invoices/new?sale=${order.id}'),
                  ),
                ];
                if (constraints.maxWidth < 560) {
                  return Column(
                    children: [
                      choices[0],
                      const SizedBox(height: Insets.md),
                      choices[1],
                    ],
                  );
                }
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: choices[0]),
                      const SizedBox(width: Insets.md),
                      Expanded(child: choices[1]),
                    ],
                  ),
                );
              },
            ),
            if (collectable != null) ...[
              const SizedBox(height: Insets.md),
              FilledButton.icon(
                onPressed: () =>
                    context.go('/invoices/${collectable.id}?pay=1'),
                icon: const Icon(Icons.price_check_rounded, size: 18),
                label: Text(
                  'Record payment on ${collectable.reference} · '
                  '${money(collectable.balanceDue, currency)} due',
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _PayChoice extends StatelessWidget {
  const _PayChoice({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: p.accent),
              const SizedBox(width: Insets.sm),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(body, style: TextStyle(fontSize: 13, color: p.inkSecondary)),
          const SizedBox(height: Insets.md),
          OutlinedButton(onPressed: onTap, child: Text(action)),
        ],
      ),
    );
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

/// One movement of stock this sale caused: which item, which document took
/// it, how many, and the stock balance it left.
class _TakenRow extends StatelessWidget {
  const _TakenRow({required this.movement});

  final Movement movement;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final change = movement.after - movement.before;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                movement.itemName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
              Text(
                '${movement.note.isEmpty ? 'Stock change' : movement.note} · '
                '${dateTimeLabel(movement.at)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: p.inkMuted),
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
              change > 0
                  ? '+${number(change)} back'
                  : '${number(-change)} taken',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: change > 0 ? p.goodText : p.ink,
              ),
            ),
            Text(
              'Balance ${number(movement.after)}',
              style: TextStyle(fontSize: 12.5, color: p.inkMuted),
            ),
          ],
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
    this.leftToBill = 0,
    required this.showStock,
  });

  final SalesOrderLine line;
  final String currency;
  final int? onHand;
  final bool showStock;

  /// Still to be billed on this line, and so still to leave the shelf.
  final int leftToBill;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final short = showStock && leftToBill > (onHand ?? 0);

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
                '${number(line.quantityFulfilled)} taken from stock · '
                '${number(leftToBill)} still to bill'
                '${showStock && onHand != null ? ' · ${number(onHand!)} in stock now' : ''}',
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
                      Flexible(
                        child: Text(
                          (onHand ?? 0) <= 0
                              ? 'Out of stock: ${number(leftToBill)} cannot be billed'
                              : 'Only ${number(onHand ?? 0)} in stock for '
                                    '${number(leftToBill)} still to bill',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.warningText,
                          ),
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

/// The order's PDF, built the same way everywhere it is offered.
SalesOrderDocument salesOrderDocument(
  InventoryController controller,
  SalesOrder order,
) => SalesOrderDocument(order, controller.settings, itemById: controller.byId);

Future<void> _share(
  BuildContext context,
  InventoryController controller,
  SalesOrder order,
) {
  final customer = controller.customerById(order.customerId);
  final doc = salesOrderDocument(controller, order);
  return showDocumentShareSheet(
    context,
    ShareableDocument(
      title: 'Sales order ${order.reference}',
      filename: doc.filename('pdf'),
      summary: doc.summary(),
      buildPdf: doc.toPdf,
      onView: () => context.go('/sales-orders/${order.id}/view'),
      recipientPhone: customer?.phone,
      recipientEmail: customer?.email,
    ),
  );
}

/// Saves the order's PDF: to Downloads in a browser, through the share sheet
/// on a phone. Busy while the file is built, so a second tap cannot start a
/// second one.
class _DownloadButton extends StatefulWidget {
  const _DownloadButton({required this.order});

  final SalesOrder order;

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  bool _busy = false;

  Future<void> _download(Rect? origin) async {
    final controller = context.read<InventoryController>();
    setState(() => _busy = true);
    try {
      final doc = salesOrderDocument(controller, widget.order);
      await const ExportService().shareBytes(
        filename: doc.filename('pdf'),
        bytes: await doc.toPdf(),
        mimeType: 'application/pdf',
        originRect: origin,
      );
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          'That file could not be produced: $error',
          tone: MessageTone.failure,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : () => _download(shareOriginOf(context)),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined, size: 18),
      label: const Text('Download PDF'),
    );
  }
}

/// The sales order as the document it prints, on its own URL, like an
/// invoice's.
class SalesOrderDocumentPage extends StatelessWidget {
  const SalesOrderDocumentPage({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<InventoryController>();
    final order = controller.salesOrderById(orderId);
    if (order == null) {
      return DocumentGone(
        what: 'Sales order',
        onBack: () => context.go('/sales-orders'),
      );
    }

    final doc = salesOrderDocument(controller, order);
    return DocumentViewPage(
      title: order.reference,
      subtitle: order.customerName.isEmpty
          ? 'Sales order'
          : 'Sales order for ${order.customerName}',
      filename: doc.filename('pdf'),
      build: doc.toPdf,
    );
  }
}
