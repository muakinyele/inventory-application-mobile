import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import '../data/receipt_document.dart';
import '../models/receipt.dart';
import '../state/inventory_controller.dart';
import 'document_view_page.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/document_share_sheet.dart';
import 'widgets/receipt_export_sheet.dart';
import 'widgets/section_card.dart';
import 'widgets/status_pill.dart';

class ReceiptDetailPage extends StatefulWidget {
  const ReceiptDetailPage({super.key, required this.receiptId});

  final String receiptId;

  @override
  State<ReceiptDetailPage> createState() => _ReceiptDetailPageState();
}

class _ReceiptDetailPageState extends State<ReceiptDetailPage> {
  /// True while a PDF is being built. Rendering a document is the one thing
  /// on this screen slow enough to need saying so.
  bool _exporting = false;

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final receipt = controller.receiptById(widget.receiptId);
    final p = context.palette;

    if (receipt == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Receipt not found',
          body: 'It may have been deleted.',
          action: FilledButton(
            onPressed: () => context.go('/receipts'),
            child: const Text('Back to receipts'),
          ),
        ),
      );
    }

    final currency = controller.settings.currency;
    final voided = receipt.status == ReceiptStatus.voided;
    final owing = receipt.balanceDue > 0 && receipt.status.countsAsSale;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: receipt.reference,
              subtitle: [
                receipt.customerName.isEmpty ? 'Walk-in' : receipt.customerName,
                dateTimeLabel(receipt.issuedAt),
              ].join(' · '),
              showBack: true,
              actions: [
                OutlinedButton.icon(
                  onPressed: () => context.go('/receipts/${receipt.id}/view'),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View'),
                ),
                Builder(
                  builder: (buttonContext) => FilledButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _export(
                            shareOriginOf(buttonContext),
                            receipt,
                            ReceiptFormat.pdf,
                          ),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('Download PDF'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _exporting
                      ? null
                      : () => _share(controller, receipt),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  // "Share", like the sales order: this hands the document to
                  // another app or a message, it does not send anything itself.
                  label: const Text('Share'),
                ),
                Builder(
                  builder: (buttonContext) => TextButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _exportAs(buttonContext, receipt),
                    icon: const Icon(Icons.more_horiz, size: 18),
                    label: const Text('Other formats'),
                  ),
                ),
              ],
            ),
            if (voided) ...[
              _VoidBanner(receipt: receipt),
              const SizedBox(height: Insets.lg),
            ],
            SectionCard(
              child: Wrap(
                spacing: Insets.section,
                runSpacing: Insets.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ReceiptStatusPill(
                    status: receipt.status,
                    unpaid: owing && !receipt.method.isDeferred,
                  ),
                  _Fact(label: 'Payment', value: receipt.method.label),
                  _Fact(
                    label: 'Items',
                    value:
                        '${number(receipt.unitsKept)} of '
                        '${number(receipt.units)}',
                  ),
                  _Fact(label: 'Total', value: money(receipt.total, currency)),
                  if (receipt.cashier.isNotEmpty)
                    _Fact(label: 'Served by', value: receipt.cashier),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final (index, line) in receipt.lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineRow(line: line, currency: currency),
                  ],
                  if (receipt.lines.isEmpty)
                    Text(
                      'This receipt has no lines.',
                      style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Totals',
              child: Column(
                children: [
                  _Total(
                    label: 'Subtotal',
                    value: money(receipt.gross, currency),
                  ),
                  if (receipt.discountTotal > 0)
                    _Total(
                      label: 'Discount',
                      value: '-${money(receipt.discountTotal, currency)}',
                    ),
                  if (receipt.taxRate > 0)
                    _Total(
                      label:
                          '${receipt.taxLabel} '
                          '(${_percent(receipt.taxRate)})',
                      value: money(receipt.tax, currency),
                    ),
                  Divider(color: p.line, height: Insets.xl),
                  _Total(
                    label: 'Total',
                    value: money(receipt.total, currency),
                    strong: true,
                  ),
                  _Total(
                    label: 'Paid',
                    value: money(receipt.amountPaid, currency),
                  ),
                  if (receipt.change > 0)
                    _Total(
                      label: 'Change given',
                      value: money(receipt.change, currency),
                      tone: p.goodText,
                    ),
                  if (owing)
                    _Total(
                      label: receipt.method.isDeferred
                          ? 'On account'
                          : 'Still owed',
                      value: money(receipt.balanceDue, currency),
                      tone: p.critical,
                    ),
                  if (receipt.refundTotal > 0) ...[
                    Divider(color: p.line, height: Insets.xl),
                    _Total(
                      label: 'Refunded',
                      value: '-${money(receipt.refundTotal, currency)}',
                      tone: p.warningText,
                    ),
                    _Total(
                      label: 'Net total',
                      value: money(receipt.netTotal, currency),
                      strong: true,
                    ),
                  ],
                ],
              ),
            ),
            if (!voided && receipt.unitsKept > 0) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Margin on what was kept',
                child: Wrap(
                  spacing: Insets.section,
                  runSpacing: Insets.md,
                  children: [
                    _Fact(
                      label: 'Revenue',
                      value: money(receipt.subtotalKept, currency),
                    ),
                    _Fact(
                      label: 'Cost of goods',
                      value: money(receipt.costOfGoods, currency),
                    ),
                    _Fact(
                      label: 'Gross profit',
                      value: money(receipt.grossProfit, currency),
                      tone: receipt.grossProfit < 0 ? p.critical : p.goodText,
                    ),
                    _Fact(
                      label: 'Margin',
                      value: receipt.marginRate == null
                          ? '—'
                          : '${(receipt.marginRate! * 100).toStringAsFixed(1)}%',
                      tone: (receipt.marginRate ?? 0) < 0
                          ? p.critical
                          : p.goodText,
                    ),
                  ],
                ),
              ),
            ],
            if (receipt.notes.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Notes',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    receipt.notes,
                    style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
                  ),
                ),
              ),
            ],
            if (receipt.salesOrderId != null || receipt.invoiceId != null) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Raised against',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: [
                      if (receipt.invoiceId != null)
                        OutlinedButton.icon(
                          onPressed: () =>
                              context.go('/invoices/${receipt.invoiceId}'),
                          icon: const Icon(
                            Icons.description_outlined,
                            size: 18,
                          ),
                          label: Text(
                            controller
                                    .invoiceById(receipt.invoiceId!)
                                    ?.reference ??
                                'The invoice it pays',
                          ),
                        ),
                      if (receipt.salesOrderId != null)
                        OutlinedButton.icon(
                          onPressed: () => context.go(
                            '/sales-orders/${receipt.salesOrderId}',
                          ),
                          icon: const Icon(
                            Icons.request_quote_outlined,
                            size: 18,
                          ),
                          label: Text(
                            controller
                                    .salesOrderById(receipt.salesOrderId!)
                                    ?.reference ??
                                'The sale it settles',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: Insets.xl),
            Wrap(
              spacing: Insets.md,
              runSpacing: Insets.md,
              children: [
                if (owing)
                  OutlinedButton.icon(
                    onPressed: () => _settle(controller, receipt),
                    icon: const Icon(Icons.payments_outlined, size: 18),
                    label: const Text('Record payment'),
                  ),
                if (receipt.status.isRefundable && receipt.unitsKept > 0)
                  OutlinedButton.icon(
                    onPressed: () => _refund(controller, receipt),
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    label: const Text('Refund'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.warningText,
                      side: BorderSide(
                        color: p.warningText.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                if (receipt.status == ReceiptStatus.issued &&
                    receipt.unitsRefunded == 0)
                  OutlinedButton.icon(
                    onPressed: () => _void(controller, receipt),
                    icon: const Icon(Icons.block_rounded, size: 18),
                    label: const Text('Void'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.critical,
                      side: BorderSide(
                        color: p.critical.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _percent(double rate) {
    final percent = rate * 100;
    return '${percent.toStringAsFixed(percent % 1 == 0 ? 0 : 2)}%';
  }

  // --- Actions -------------------------------------------------------------

  Future<void> _export(
    Rect? origin,
    Receipt receipt,
    ReceiptFormat format,
  ) async {
    final settings = context.read<InventoryController>().settings;
    setState(() => _exporting = true);
    try {
      await exportReceipt(
        receipt: receipt,
        settings: settings,
        format: format,
        originRect: origin,
      );
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
    if (mounted) _notify('${receipt.reference} exported as ${format.label}');
  }

  /// Offers every way this receipt can reach the customer.
  ///
  /// The summary is what a deep link carries, so it has to stand on its own:
  /// somebody reading it in WhatsApp sees no attachment, and "please find
  /// attached" would be a lie there.
  Future<void> _share(InventoryController controller, Receipt receipt) async {
    final settings = controller.settings;
    final customer = controller.customerById(receipt.customerId);
    final doc = ReceiptDocument(receipt, settings);

    final lines = [
      '${settings.companyName} — receipt ${receipt.reference}',
      if (receipt.customerName.isNotEmpty) 'For: ${receipt.customerName}',
      'Date: ${dateTimeLabel(receipt.issuedAt)}',
      '',
      for (final line in receipt.lines)
        '${line.quantity} × ${line.itemName} — '
            '${money(line.net, settings.currency)}',
      '',
      'Total: ${money(receipt.total, settings.currency)}',
      if (receipt.balanceDue > 0)
        'Outstanding: ${money(receipt.balanceDue, settings.currency)}'
      else
        'Paid in full — thank you.',
    ];

    await showDocumentShareSheet(
      context,
      ShareableDocument(
        title: 'Receipt ${receipt.reference}',
        filename: doc.filename('pdf'),
        summary: lines.join('\n'),
        buildPdf: doc.toPdf,
        onView: () => context.go('/receipts/${receipt.id}/view'),
        recipientPhone: customer?.phone,
        recipientEmail: customer?.email,
      ),
    );
  }

  Future<void> _exportAs(BuildContext buttonContext, Receipt receipt) async {
    // Read before the sheet opens, while the button is still on screen.
    final origin = shareOriginOf(buttonContext);
    final format = await pickReceiptFormat(context);
    if (format == null || !mounted) return;
    await _export(origin, receipt, format);
  }

  Future<void> _settle(InventoryController controller, Receipt receipt) async {
    final currency = controller.settings.currency;
    final field = TextEditingController(
      text: receipt.balanceDue.toStringAsFixed(2),
    );
    PaymentMethod method = receipt.method;

    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record payment'),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${money(receipt.balanceDue, currency)} outstanding on '
                '${receipt.reference}.',
                style: const TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: field,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount (${currencySymbol(currency)})',
                ),
              ),
              const SizedBox(height: Insets.md),
              DropdownButtonFormField<PaymentMethod>(
                initialValue: method,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Paid by'),
                items: [
                  for (final m in PaymentMethod.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (value) =>
                    setDialogState(() => method = value ?? method),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(parseAmount(field.text) ?? 0),
            child: const Text('Record'),
          ),
        ],
      ),
    );
    field.dispose();

    if (amount == null || amount <= 0) return;

    // Awaited, and reported. This said "recorded" the instant it was tapped,
    // for a write that never left the device — and now that it does leave,
    // the server decides how much of the offer was actually owed. It answers
    // with what it took; the difference is the customer's change.
    final applied = await controller.settleReceipt(
      receipt.id,
      amount,
      method: method,
    );
    if (!mounted) return;

    if (applied == null) {
      await _notify(
        'That payment was not recorded, so nothing was changed. '
        'Check your connection and try again.',
        tone: MessageTone.failure,
      );
      return;
    }

    final change = amount - applied;
    _notify(
      change < 0.005
          ? '${money(applied, currency)} recorded'
          : '${money(applied, currency)} recorded · '
                '${money(change, currency)} change',
    );
  }

  Future<void> _refund(InventoryController controller, Receipt receipt) async {
    final result = await showModalBottomSheet<(Map<String, int>, bool)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RefundSheet(receipt: receipt),
    );
    if (result == null) return;

    final (quantities, restock) = result;
    final refunded = await controller.refundReceipt(
      receipt.id,
      quantities,
      restock: restock,
    );
    if (!mounted) return;
    _notify(
      refunded == 0
          ? 'Nothing to refund'
          : 'Refunded ${refunded == 1 ? '1 line' : '$refunded lines'}'
                '${restock ? ' and put the goods back' : ''}',
      tone: refunded == 0 ? MessageTone.warning : MessageTone.success,
    );
  }

  Future<void> _void(InventoryController controller, Receipt receipt) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Void receipt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              receipt.movesStock
                  ? 'Strike ${receipt.reference} off. Everything on it goes '
                        'back on the shelf, and it stops counting towards '
                        'takings.'
                  : 'Strike ${receipt.reference} off. It stops counting '
                        'towards takings. No stock moves — the sale it '
                        'settles is what sent the goods.',
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              controller: reason,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'Optional — printed on the voided receipt',
              ),
            ),
          ],
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
            child: const Text('Void receipt'),
          ),
        ],
      ),
    );

    final text = reason.text.trim();
    reason.dispose();
    if (confirmed != true) return;

    final done = await controller.voidReceipt(receipt.id, reason: text);
    if (mounted) {
      _notify(
        done ? '${receipt.reference} voided' : 'That receipt cannot be voided',
        tone: done ? MessageTone.success : MessageTone.failure,
      );
    }
  }
}

/// The receipt as the document it prints, on its own URL. Read once and not
/// listened to, for the same reason as the invoice: it is a snapshot.
class ReceiptDocumentPage extends StatelessWidget {
  const ReceiptDocumentPage({super.key, required this.receiptId});

  final String receiptId;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<InventoryController>();
    final receipt = controller.receiptById(receiptId);
    if (receipt == null) {
      return DocumentGone(
        what: 'Receipt',
        onBack: () => context.go('/receipts'),
      );
    }

    final doc = ReceiptDocument(receipt, controller.settings);
    return DocumentViewPage(
      title: receipt.reference,
      subtitle: receipt.customerName.isEmpty
          ? 'Receipt'
          : 'Receipt for ${receipt.customerName}',
      filename: doc.filename('pdf'),
      build: doc.toPdf,
    );
  }
}

class _VoidBanner extends StatelessWidget {
  const _VoidBanner({required this.receipt});

  final Receipt receipt;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: p.criticalWash,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.critical.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.block_rounded, size: 20, color: p.critical),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'This receipt has been voided',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: p.critical,
                  ),
                ),
                Text(
                  receipt.voidReason.isEmpty
                      ? 'It does not count towards takings.'
                      : receipt.voidReason,
                  style: TextStyle(fontSize: 12.5, color: p.inkSecondary),
                ),
              ],
            ),
          ),
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

class _Total extends StatelessWidget {
  const _Total({
    required this.label,
    required this.value,
    this.strong = false,
    this.tone,
  });

  final String label;
  final String value;
  final bool strong;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: strong ? 15 : 13.5,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              color: tone ?? (strong ? p.ink : p.inkSecondary),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: strong ? 17 : 13.5,
              fontWeight: FontWeight.w700,
              color: tone ?? p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.currency});

  final ReceiptLine line;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

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
                [
                  '${number(line.quantity)} ${line.unit}',
                  '${money(line.unitPrice, currency)} each',
                  if (line.sku.isNotEmpty) line.sku,
                ].join(' · '),
                style: TextStyle(fontSize: 12.5, color: p.inkMuted),
              ),
              if (line.quantityRefunded > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.undo_rounded, size: 13, color: p.warningText),
                      const SizedBox(width: 4),
                      Text(
                        '${number(line.quantityRefunded)} returned',
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
              money(line.net, currency),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: p.ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (line.discount > 0)
              Text(
                '-${money(line.discount, currency)} off',
                style: TextStyle(fontSize: 12, color: p.inkMuted),
              ),
          ],
        ),
      ],
    );
  }
}

/// Asks what is coming back, pre-filled with everything still un-refunded,
/// and whether it goes back on the shelf.
class _RefundSheet extends StatefulWidget {
  const _RefundSheet({required this.receipt});

  final Receipt receipt;

  @override
  State<_RefundSheet> createState() => _RefundSheetState();
}

class _RefundSheetState extends State<_RefundSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final line in widget.receipt.lines)
      if (line.quantityKept > 0)
        line.id: TextEditingController(text: '${line.quantityKept}'),
  };
  bool _restock = true;

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
    final returnable = widget.receipt.lines
        .where((l) => l.quantityKept > 0)
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
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
                  'Refund ${widget.receipt.reference}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Enter what is coming back. Anything left stays sold.',
                  style: TextStyle(fontSize: 13, color: p.inkSecondary),
                ),
                const SizedBox(height: Insets.lg),
                for (final line in returnable) ...[
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
                              '${number(line.quantityKept)} of '
                              '${number(line.quantity)} still sold',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: p.inkMuted,
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
                SwitchListTile(
                  value: _restock,
                  onChanged: (value) => setState(() => _restock = value),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Put the goods back on the shelf',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _restock
                        ? 'Stock goes back up and the ledger records it.'
                        : 'The money is returned but no stock comes back — '
                              'for goods that are damaged or written off.',
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                ),
                const SizedBox(height: Insets.sm),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop((
                    {
                      for (final entry in _fields.entries)
                        entry.key: int.tryParse(entry.value.text.trim()) ?? 0,
                    },
                    _restock,
                  )),
                  child: const Text('Refund'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
