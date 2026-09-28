import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import '../data/invoice_document.dart';
import '../models/invoice.dart';
import '../models/receipt.dart';
import '../state/inventory_controller.dart';
import 'document_view_page.dart';
import 'widgets/app_message.dart';
import 'widgets/document_link_row.dart';
import 'widgets/document_share_sheet.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/status_pill.dart';

class InvoiceDetailPage extends StatefulWidget {
  const InvoiceDetailPage({super.key, required this.invoiceId});

  final String invoiceId;

  @override
  State<InvoiceDetailPage> createState() => _InvoiceDetailPageState();
}

class _InvoiceDetailPageState extends State<InvoiceDetailPage> {
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
    final invoice = controller.invoiceById(widget.invoiceId);
    final p = context.palette;

    if (invoice == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Invoice not found',
          body: 'It may have been deleted.',
          action: FilledButton(
            onPressed: () => context.go('/invoices'),
            child: const Text('Back to invoices'),
          ),
        ),
      );
    }

    final currency = controller.settings.currency;
    final payments = controller.paymentsForInvoice(invoice.id);
    final cancelled = invoice.status == InvoiceStatus.cancelled;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: invoice.reference,
              subtitle: [
                invoice.customerName.isEmpty
                    ? 'Account customer'
                    : invoice.customerName,
                'issued ${dayLabel(invoice.issuedAt)}',
                if (invoice.dueAt != null) 'due ${dayLabel(invoice.dueAt!)}',
              ].join(' · '),
              showBack: true,
              actions: [
                if (invoice.status.isCollectable)
                  FilledButton.icon(
                    onPressed: () => _takePayment(controller, invoice),
                    icon: const Icon(Icons.payments_outlined, size: 18),
                    label: const Text('Record payment'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/invoices/${invoice.id}/view'),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View'),
                ),
                Builder(
                  builder: (buttonContext) => OutlinedButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _exportPdf(
                            shareOriginOf(buttonContext),
                            invoice,
                            payments,
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
                      : () => _share(invoice, payments),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Send'),
                ),
              ],
            ),
            if (cancelled) ...[
              _Banner(
                icon: Icons.block_rounded,
                title: 'This invoice has been cancelled',
                body: invoice.cancelledReason.isEmpty
                    ? 'It does not count as a sale.'
                    : invoice.cancelledReason,
                tone: p.critical,
                wash: p.criticalWash,
              ),
              const SizedBox(height: Insets.lg),
            ] else if (invoice.isOverdue) ...[
              _Banner(
                icon: Icons.priority_high_rounded,
                title:
                    'Overdue by ${invoice.daysOverdue} '
                    '${invoice.daysOverdue == 1 ? 'day' : 'days'}',
                body:
                    '${money(invoice.balanceDue, currency)} was due on '
                    '${dayLabel(invoice.dueAt!)}.',
                tone: p.critical,
                wash: p.criticalWash,
              ),
              const SizedBox(height: Insets.lg),
            ],
            SectionCard(
              child: Wrap(
                spacing: Insets.section,
                runSpacing: Insets.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InvoiceStatusPill(
                    status: invoice.status,
                    overdue: invoice.isOverdue,
                  ),
                  _Fact(label: 'Total', value: money(invoice.total, currency)),
                  _Fact(
                    label: 'Paid',
                    value: money(invoice.amountPaid, currency),
                  ),
                  _Fact(
                    label: 'Balance',
                    value: money(invoice.balanceDue, currency),
                    tone: invoice.isSettled ? p.goodText : p.warningText,
                  ),
                  if (invoice.terms.isNotEmpty)
                    _Fact(label: 'Terms', value: invoice.terms),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final (index, line) in invoice.lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineRow(line: line, currency: currency),
                  ],
                  if (invoice.lines.isEmpty)
                    Text(
                      'This invoice has no lines.',
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
                    value: money(invoice.gross, currency),
                  ),
                  if (invoice.discountTotal > 0)
                    _Total(
                      label: 'Discount',
                      value: '-${money(invoice.discountTotal, currency)}',
                    ),
                  if (invoice.taxRate > 0)
                    _Total(
                      label:
                          '${invoice.taxLabel} '
                          '(${_percent(invoice.taxRate)})',
                      value: money(invoice.tax, currency),
                    ),
                  Divider(color: p.line, height: Insets.xl),
                  _Total(
                    label: 'Invoice total',
                    value: money(invoice.total, currency),
                    strong: true,
                  ),
                  for (final payment in payments)
                    _Total(
                      label:
                          '${payment.reference} · ${payment.method.label} · '
                          '${dayLabel(payment.at)}',
                      value: '-${money(payment.amount, currency)}',
                      tone: p.goodText,
                    ),
                  Divider(color: p.line, height: Insets.xl),
                  _Total(
                    label: invoice.isSettled ? 'Paid in full' : 'Balance due',
                    value: money(invoice.balanceDue, currency),
                    strong: true,
                    tone: invoice.isSettled
                        ? p.goodText
                        : (invoice.isOverdue ? p.critical : p.warningText),
                  ),
                ],
              ),
            ),
            if (!cancelled && invoice.revenue > 0) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Margin on this sale',
                child: Wrap(
                  spacing: Insets.section,
                  runSpacing: Insets.md,
                  children: [
                    _Fact(
                      label: 'Revenue',
                      value: money(invoice.revenue, currency),
                    ),
                    _Fact(
                      label: 'Cost of goods',
                      value: money(invoice.costOfGoods, currency),
                    ),
                    _Fact(
                      label: 'Gross profit',
                      value: money(invoice.grossProfit, currency),
                      tone: invoice.grossProfit < 0 ? p.critical : p.goodText,
                    ),
                    _Fact(
                      label: 'Margin',
                      value: invoice.marginRate == null
                          ? '—'
                          : '${(invoice.marginRate! * 100).toStringAsFixed(1)}%',
                      tone: (invoice.marginRate ?? 0) < 0
                          ? p.critical
                          : p.goodText,
                    ),
                  ],
                ),
              ),
            ],
            if (payments.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Receipts issued',
                child: Column(
                  children: [
                    for (final (index, payment) in payments.indexed) ...[
                      if (index > 0) Divider(color: p.line, height: Insets.lg),
                      DocumentLinkRow(
                        reference: payment.reference,
                        detail:
                            '${payment.method.label} · '
                            '${dateTimeLabel(payment.at)}',
                        amount: money(payment.amount, currency),
                        onOpen: () =>
                            context.go('/receipts/${payment.receiptId}'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (invoice.notes.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Notes',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    invoice.notes,
                    style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
                  ),
                ),
              ),
            ],
            if (invoice.salesOrderId != null) ...[
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Raised against',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        context.go('/sales-orders/${invoice.salesOrderId}'),
                    icon: const Icon(Icons.request_quote_outlined, size: 18),
                    label: Text(
                      controller
                              .salesOrderById(invoice.salesOrderId!)
                              ?.reference ??
                          'The sale it bills',
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: Insets.xl),
            Wrap(
              spacing: Insets.md,
              runSpacing: Insets.md,
              children: [
                if (invoice.status == InvoiceStatus.open &&
                    invoice.amountPaid == 0)
                  OutlinedButton.icon(
                    onPressed: () => _cancel(controller, invoice),
                    icon: const Icon(Icons.block_rounded, size: 18),
                    label: const Text('Cancel invoice'),
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

  /// Offers every way this invoice can reach the customer.
  ///
  /// An invoice's message leads with what is owed and by when, because that
  /// is the reason it is being sent — and a deep link carries no attachment,
  /// so the figure has to be in the words.
  Future<void> _share(Invoice invoice, List<InvoicePayment> payments) async {
    final controller = context.read<InventoryController>();
    final settings = controller.settings;
    final customer = controller.customerById(invoice.customerId);
    final doc = InvoiceDocument(invoice, settings, payments: payments);

    final lines = [
      '${settings.companyName} — invoice ${invoice.reference}',
      if (invoice.customerName.isNotEmpty) 'For: ${invoice.customerName}',
      'Issued: ${longDate(invoice.issuedAt)}',
      if (invoice.dueAt != null) 'Due: ${longDate(invoice.dueAt!)}',
      '',
      for (final line in invoice.lines)
        '${line.quantity} × ${line.itemName} — '
            '${money(line.net, settings.currency)}',
      '',
      'Total: ${money(invoice.total, settings.currency)}',
      if (invoice.balanceDue > 0)
        'Balance due: ${money(invoice.balanceDue, settings.currency)}'
      else
        'Settled in full — thank you.',
      if (settings.companyPhone.isNotEmpty) '',
      if (settings.companyPhone.isNotEmpty)
        'Questions? ${settings.companyPhone}',
    ];

    await showDocumentShareSheet(
      context,
      ShareableDocument(
        title: 'Invoice ${invoice.reference}',
        filename: doc.filename('pdf'),
        summary: lines.join('\n'),
        buildPdf: doc.toPdf,
        onView: () => context.go('/invoices/${invoice.id}/view'),
        recipientPhone: customer?.phone,
        recipientEmail: customer?.email,
      ),
    );
  }

  Future<void> _exportPdf(
    Rect? origin,
    Invoice invoice,
    List<InvoicePayment> payments,
  ) async {
    final settings = context.read<InventoryController>().settings;
    setState(() => _exporting = true);
    try {
      final doc = InvoiceDocument(invoice, settings, payments: payments);
      await const ExportService().shareBytes(
        filename: doc.filename('pdf'),
        bytes: await doc.toPdf(),
        mimeType: 'application/pdf',
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
    if (mounted) _notify('${invoice.reference} exported');
  }

  /// Takes money against the invoice and issues the receipt for it — the
  /// point where a credit sale turns into a paid one.
  Future<void> _takePayment(
    InventoryController controller,
    Invoice invoice,
  ) async {
    final currency = controller.settings.currency;
    final field = TextEditingController(
      text: invoice.balanceDue.toStringAsFixed(2),
    );
    var method = PaymentMethod.cash;

    final result = await showDialog<(double, PaymentMethod)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record payment'),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${money(invoice.balanceDue, currency)} outstanding on '
                '${invoice.reference}.',
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
                  helperText: 'A receipt is issued for whatever is paid',
                ),
              ),
              const SizedBox(height: Insets.md),
              DropdownButtonFormField<PaymentMethod>(
                initialValue: method,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Paid by'),
                items: [
                  for (final m in PaymentMethod.values)
                    if (m != PaymentMethod.credit)
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
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop((parseAmount(field.text) ?? 0, method)),
            child: const Text('Record and receipt'),
          ),
        ],
      ),
    );
    field.dispose();

    if (result == null) return;
    final (amount, chosen) = result;
    if (amount <= 0) return;

    final receipt = await controller.payInvoice(
      invoice.id,
      amount,
      method: chosen,
    );
    if (!mounted) return;
    if (receipt == null) {
      _notify('That payment could not be recorded.', tone: MessageTone.failure);
      return;
    }
    _notify('${receipt.reference} issued for ${money(amount, currency)}');
  }

  Future<void> _cancel(InventoryController controller, Invoice invoice) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel invoice'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              invoice.movesStock
                  ? 'Strike ${invoice.reference} off. Everything on it goes '
                        'back on the shelf, and it stops counting as a sale.'
                  : 'Strike ${invoice.reference} off. It stops counting as a '
                        'sale. No stock moves — the order it bills is what '
                        'sent the goods.',
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              controller: reason,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'Optional — printed on the cancelled invoice',
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
            child: const Text('Cancel invoice'),
          ),
        ],
      ),
    );

    final text = reason.text.trim();
    reason.dispose();
    if (confirmed != true) return;

    // Awaited: the cancellation reaches the server now, so it can fail — and
    // reporting success before the request has been answered is what made the
    // old version look like it worked.
    final done = await controller.cancelInvoice(invoice.id, reason: text);
    if (mounted) {
      _notify(
        done
            ? '${invoice.reference} cancelled'
            : 'That invoice could not be cancelled, so nothing was changed.',
        tone: done ? MessageTone.success : MessageTone.failure,
      );
    }
  }
}

/// The invoice as the document it prints, on its own URL.
///
/// The figures are read once, without listening: a document is a snapshot of
/// what was billed, and re-rendering it under someone who is reading it would
/// only throw their place away.
class InvoiceDocumentPage extends StatelessWidget {
  const InvoiceDocumentPage({super.key, required this.invoiceId});

  final String invoiceId;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<InventoryController>();
    final invoice = controller.invoiceById(invoiceId);
    if (invoice == null) {
      return DocumentGone(
        what: 'Invoice',
        onBack: () => context.go('/invoices'),
      );
    }

    final doc = InvoiceDocument(
      invoice,
      controller.settings,
      payments: controller.paymentsForInvoice(invoice.id),
    );
    return DocumentViewPage(
      title: invoice.reference,
      subtitle: invoice.customerName.isEmpty
          ? 'Invoice'
          : 'Invoice for ${invoice.customerName}',
      filename: doc.filename('pdf'),
      build: doc.toPdf,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.title,
    required this.body,
    required this.tone,
    required this.wash,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color tone;
  final Color wash;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: tone),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: tone,
                  ),
                ),
                Text(
                  body,
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
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: strong ? 15 : 13.5,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                color: tone ?? (strong ? p.ink : p.inkSecondary),
              ),
            ),
          ),
          const SizedBox(width: Insets.md),
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

  final InvoiceLine line;
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
