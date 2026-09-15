import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../models/party.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Raises a receipt.
///
/// Two shapes, one screen. With no [salesOrderId] this is a counter sale: pick
/// what is going out, take the money, and the stock leaves the shelf as the
/// receipt is issued. With one, the lines are fixed to what that sale already
/// despatched — the goods have gone, and this is only the paperwork for the
/// payment — so they are shown but not editable.
class ReceiptEditorPage extends StatefulWidget {
  const ReceiptEditorPage({super.key, this.salesOrderId});

  final String? salesOrderId;

  @override
  State<ReceiptEditorPage> createState() => _ReceiptEditorPageState();
}

class _ReceiptEditorPageState extends State<ReceiptEditorPage> {
  SalesOrder? _order;
  String? _customerId;
  PaymentMethod _method = PaymentMethod.cash;
  final _lines = <_LineDraft>[];
  final _discount = TextEditingController();
  final _paid = TextEditingController();
  final _notes = TextEditingController();
  final _cashier = TextEditingController();
  bool _initialised = false;

  /// Set once the seller types into the paid field, so the running total no
  /// longer keeps it in step with the bill.
  bool _paidEdited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;

    final controller = context.read<InventoryController>();
    final order = widget.salesOrderId == null
        ? null
        : controller.salesOrderById(widget.salesOrderId!);
    _order = order;

    if (order == null) {
      _lines.add(_LineDraft.empty());
      return;
    }

    _customerId = order.customerId;
    _lines.addAll(
      controller.receiptLinesForSalesOrder(order).map(_LineDraft.fromLine),
    );
    _syncPaid();
  }

  @override
  void dispose() {
    _discount.dispose();
    _paid.dispose();
    _notes.dispose();
    _cashier.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  InventoryController get _controller => context.read<InventoryController>();

  bool get _fromSale => _order != null;

  List<ReceiptLine> _buildLines() => [
    for (final line in _lines)
      if (line.itemId != null && line.quantity > 0)
        ReceiptLine(
          id: line.id,
          itemId: line.itemId!,
          itemName: line.itemName,
          sku: line.sku,
          unit: line.unit,
          quantity: line.quantity,
          unitPrice: line.price,
          discount: line.discount,
          costOfGoods: line.costOfGoods,
        ),
  ];

  double get _gross => _buildLines().fold(0.0, (sum, l) => sum + l.gross);

  double get _lineDiscount =>
      _buildLines().fold(0.0, (sum, l) => sum + l.discount);

  double get _billDiscount => parseAmount(_discount.text) ?? 0;

  double get _subtotal {
    final off = (_lineDiscount + _billDiscount).clamp(0, _gross);
    return (_gross - off).clamp(0, double.infinity).toDouble();
  }

  double get _taxRate => _controller.settings.taxRate;

  double get _total => _subtotal * (1 + _taxRate);

  /// Keeps the tendered figure equal to the bill until the seller overrides
  /// it — the common case is paying exactly, and typing it twice is friction.
  void _syncPaid() {
    if (_paidEdited || _method.isDeferred) return;
    final total = _total;
    _paid.text = total == 0 ? '' : total.toStringAsFixed(2);
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  Future<void> _issue() async {
    final lines = _buildLines();
    if (lines.isEmpty) {
      _notify(
        'Add at least one line with an item and a quantity.',
        tone: MessageTone.warning,
      );
      return;
    }

    // A counter sale can not send what is not there. Checked here so the
    // seller is told, rather than having the controller silently trim it.
    if (!_fromSale) {
      final wanted = <String, int>{};
      for (final line in lines) {
        wanted[line.itemId] = (wanted[line.itemId] ?? 0) + line.quantity;
      }
      for (final entry in wanted.entries) {
        final item = _controller.byId(entry.key);
        if (item == null) continue;
        if (entry.value > item.quantity) {
          _notify(
            'Only ${number(item.quantity)} of ${item.name} on the shelf.',
            tone: MessageTone.warning,
          );
          return;
        }
      }
    }

    final receipt = await _controller.issueReceipt(
      salesOrderId: _order?.id,
      customerId: _customerId,
      method: _method,
      lines: lines,
      discount: _billDiscount,
      amountPaid: _method.isDeferred
          ? (parseAmount(_paid.text) ?? 0)
          : _tendered,
      notes: _notes.text.trim(),
      cashier: _cashier.text.trim(),
    );

    if (receipt == null) {
      _notify(
        'Nothing could be receipted — check the quantities.',
        tone: MessageTone.failure,
      );
      return;
    }
    // Awaited: routing away takes the dialog down with the page it sits on.
    await _notify('${receipt.reference} issued');
    if (!mounted) return;
    context.go('/receipts/${receipt.id}');
  }

  double get _tendered => parseAmount(_paid.text) ?? 0;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    if (widget.salesOrderId != null && _order == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Sale not found',
          body: 'It may have been deleted.',
          action: FilledButton(
            onPressed: () => context.go('/receipts'),
            child: const Text('Back to receipts'),
          ),
        ),
      );
    }

    if (_fromSale && _lines.isEmpty) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.local_shipping_outlined,
          title: 'Nothing has been sent yet',
          body:
              'A receipt covers goods the customer has actually taken. Send '
              'stock against ${_order!.reference} first, then raise the '
              'receipt for what went out.',
          action: FilledButton(
            onPressed: () => context.go('/sales-orders/${_order!.id}'),
            child: const Text('Back to the sale'),
          ),
        ),
      );
    }

    final tier = controller.priceTierFor(_customerId);
    final change = (_tendered - _total).clamp(0, double.infinity);
    final owing = (_total - _tendered).clamp(0, double.infinity);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: _fromSale
                  ? 'Receipt for ${_order!.reference}'
                  : 'New Receipt',
              subtitle: _fromSale
                  ? 'Payment for what that sale has already sent'
                  : 'Issuing this takes the stock off the shelf',
              showBack: true,
            ),
            SectionCard(
              title: 'Sale',
              child: Column(
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _customerId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Customer',
                      helperText: _fromSale
                          ? 'Taken from the sale'
                          : 'Priced at ${tier.label.toLowerCase()} rates',
                    ),
                    items: [
                      const DropdownMenuItem(child: Text('Walk-in')),
                      for (final customer in controller.customers)
                        DropdownMenuItem(
                          value: customer.id,
                          child: Text(
                            '${customer.name} · ${customer.priceTier.label}',
                          ),
                        ),
                    ],
                    onChanged: _fromSale
                        ? null
                        : (value) => setState(() {
                            _customerId = value;
                            _reprice(
                              controller.items,
                              controller.priceTierFor(value),
                            );
                            _syncPaid();
                          }),
                  ),
                  const SizedBox(height: Insets.md),
                  DropdownButtonFormField<PaymentMethod>(
                    initialValue: _method,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Payment method',
                    ),
                    items: [
                      for (final method in PaymentMethod.values)
                        DropdownMenuItem(
                          value: method,
                          child: Text(method.label),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _method = value ?? PaymentMethod.cash;
                      // An account sale is expected to leave money owing, so
                      // the tendered figure starts at nothing rather than the
                      // full bill.
                      if (_method.isDeferred && !_paidEdited) {
                        _paid.clear();
                      } else {
                        _syncPaid();
                      }
                    }),
                  ),
                  // An unpaid receipt is still supported — a customer who
                  // is short at the till — but a planned credit sale belongs
                  // on an invoice, which tracks what is owed and issues a
                  // receipt for each payment.
                  if (_method.isDeferred && !_fromSale) ...[
                    const SizedBox(height: Insets.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/invoices/new'),
                        icon: const Icon(Icons.description_outlined, size: 16),
                        label: const Text('Raise an invoice instead'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _cashier,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Served by',
                      helperText: 'Optional — printed on the receipt',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              trailing: Text(
                money(_gross, currency),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              child: Column(
                children: [
                  if (_lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                      child: Text(
                        'No lines yet. Add what the customer is taking.',
                        style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                      ),
                    ),
                  for (final (index, line) in _lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineEditor(
                      line: line,
                      items: controller.items,
                      currency: currency,
                      tier: tier,
                      locked: _fromSale,
                      onChanged: () => setState(_syncPaid),
                      onRemove: () => setState(() {
                        _lines.removeAt(index).dispose();
                        _syncPaid();
                      }),
                    ),
                  ],
                  if (!_fromSale) ...[
                    const SizedBox(height: Insets.md),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _lines.add(_LineDraft.empty())),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add line'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Payment',
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _discount,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setState(_syncPaid),
                          decoration: InputDecoration(
                            labelText:
                                'Discount off the bill '
                                '(${currencySymbol(currency)})',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      Expanded(
                        child: TextField(
                          controller: _paid,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setState(() => _paidEdited = true),
                          decoration: InputDecoration(
                            labelText:
                                'Amount paid (${currencySymbol(currency)})',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),
                  _Total(label: 'Subtotal', value: money(_gross, currency)),
                  if (_lineDiscount + _billDiscount > 0)
                    _Total(
                      label: 'Discount',
                      value:
                          '-${money((_lineDiscount + _billDiscount).clamp(0, _gross), currency)}',
                    ),
                  if (_taxRate > 0)
                    _Total(
                      label:
                          '${controller.settings.taxLabel} '
                          '(${(_taxRate * 100).toStringAsFixed(_taxRate * 100 % 1 == 0 ? 0 : 2)}%)',
                      value: money(_subtotal * _taxRate, currency),
                    ),
                  Divider(color: p.line, height: Insets.xl),
                  _Total(
                    label: 'Total',
                    value: money(_total, currency),
                    strong: true,
                  ),
                  if (change > 0)
                    _Total(
                      label: 'Change',
                      value: money(change, currency),
                      tone: p.goodText,
                    ),
                  if (owing > 0)
                    _Total(
                      label: _method.isDeferred ? 'On account' : 'Still owing',
                      value: money(owing, currency),
                      tone: _method.isDeferred ? p.inkSecondary : p.critical,
                    ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.xl),
            FilledButton.icon(
              onPressed: _issue,
              icon: const Icon(Icons.receipt_rounded, size: 18),
              label: Text('Issue receipt · ${money(_total, currency)}'),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              _fromSale
                  ? 'This records the payment only. The stock left the shelf '
                        'when the sale was sent.'
                  : 'Issuing takes the stock off the shelf and writes it to '
                        'the ledger. To undo one, void it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: p.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

  /// Re-prices every untouched line when the customer — and so the tier —
  /// changes. A price the seller typed by hand is left alone.
  void _reprice(List<Item> items, PriceTier tier) {
    for (final line in _lines) {
      if (line.priceEdited) continue;
      final item = items.where((i) => i.id == line.itemId).firstOrNull;
      if (item == null) continue;
      line.setPrice(item.priceFor(tier));
    }
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

/// Mutable working copy of a line while the form is open.
class _LineDraft {
  _LineDraft({
    required this.id,
    this.itemId,
    this.itemName = '',
    this.sku = '',
    this.unit = 'pcs',
    this.costOfGoods = 0,
    String quantity = '',
    String price = '',
    String discount = '',
  }) : quantityController = TextEditingController(text: quantity),
       priceController = TextEditingController(text: price),
       discountController = TextEditingController(text: discount);

  factory _LineDraft.empty() =>
      _LineDraft(id: UniqueKey().toString(), quantity: '1');

  factory _LineDraft.fromLine(ReceiptLine line) => _LineDraft(
    id: line.id,
    itemId: line.itemId,
    itemName: line.itemName,
    sku: line.sku,
    unit: line.unit,
    costOfGoods: line.costOfGoods,
    quantity: '${line.quantity}',
    price: line.unitPrice == 0 ? '' : '${line.unitPrice}',
    discount: line.discount == 0 ? '' : '${line.discount}',
  );

  final String id;
  String? itemId;
  String itemName;
  String sku;
  String unit;
  double costOfGoods;
  final TextEditingController quantityController;
  final TextEditingController priceController;
  final TextEditingController discountController;

  /// Set once the seller types a price, so re-tiering never overwrites a
  /// deliberate figure.
  bool priceEdited = false;

  int get quantity => int.tryParse(quantityController.text.trim()) ?? 0;
  double get price => parseAmount(priceController.text) ?? 0;
  double get discount => parseAmount(discountController.text) ?? 0;
  double get lineTotal =>
      (quantity * price - discount).clamp(0, double.infinity).toDouble();

  void setPrice(double value) {
    priceController.text = value == 0 ? '' : '$value';
  }

  void dispose() {
    quantityController.dispose();
    priceController.dispose();
    discountController.dispose();
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    required this.line,
    required this.items,
    required this.currency,
    required this.tier,
    required this.locked,
    required this.onChanged,
    required this.onRemove,
  });

  final _LineDraft line;
  final List<Item> items;
  final String currency;
  final PriceTier tier;

  /// A receipt against a sales order can not change what that sale sent, so
  /// its lines are shown read-only rather than hidden.
  final bool locked;

  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final picked = items.where((i) => i.id == line.itemId).firstOrNull;
    final short = !locked && picked != null && line.quantity > picked.quantity;

    if (locked) {
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
                  '${number(line.quantity)} ${line.unit} · '
                  '${money(line.price, currency)} each',
                  style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          Text(
            money(line.lineTotal, currency),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;

        final itemField = DropdownButtonFormField<String>(
          initialValue: picked == null ? null : line.itemId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Item', isDense: true),
          items: [
            for (final item in items)
              DropdownMenuItem(
                value: item.id,
                child: Text(
                  '${item.name}  ·  ${number(item.quantity)} in stock',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            line.itemId = value;
            final chosen = items.where((i) => i.id == value).firstOrNull;
            line.itemName = chosen?.name ?? '';
            line.sku = chosen?.sku ?? '';
            line.unit = chosen?.unit ?? 'pcs';
            if (chosen != null && !line.priceEdited) {
              line.setPrice(chosen.priceFor(tier));
            }
            onChanged();
          },
        );

        final quantityField = TextField(
          controller: line.quantityController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: 'Quantity',
            isDense: true,
            helperText: short
                ? 'Only ${number(picked.quantity)} in stock'
                : null,
            helperStyle: short
                ? TextStyle(color: p.warningText, fontWeight: FontWeight.w600)
                : null,
          ),
        );

        final priceField = TextField(
          controller: line.priceController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) {
            line.priceEdited = true;
            onChanged();
          },
          decoration: InputDecoration(
            labelText: 'Unit price (${currencySymbol(currency)})',
            isDense: true,
          ),
        );

        final discountField = TextField(
          controller: line.discountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => onChanged(),
          decoration: const InputDecoration(
            labelText: 'Discount',
            isDense: true,
          ),
        );

        final total = Text(
          money(line.lineTotal, currency),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: p.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              itemField,
              const SizedBox(height: Insets.sm),
              Row(
                children: [
                  Expanded(child: quantityField),
                  const SizedBox(width: Insets.sm),
                  Expanded(child: priceField),
                  const SizedBox(width: Insets.sm),
                  Expanded(child: discountField),
                ],
              ),
              const SizedBox(height: Insets.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  total,
                  IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove line',
                    style: IconButton.styleFrom(foregroundColor: p.critical),
                  ),
                ],
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 4, child: itemField),
            const SizedBox(width: Insets.sm),
            Expanded(flex: 2, child: quantityField),
            const SizedBox(width: Insets.sm),
            Expanded(flex: 3, child: priceField),
            const SizedBox(width: Insets.sm),
            Expanded(flex: 2, child: discountField),
            const SizedBox(width: Insets.md),
            SizedBox(
              width: 110,
              child: Padding(
                padding: const EdgeInsets.only(top: Insets.md),
                child: Align(alignment: Alignment.centerRight, child: total),
              ),
            ),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Remove line',
              style: IconButton.styleFrom(foregroundColor: p.critical),
            ),
          ],
        );
      },
    );
  }
}
