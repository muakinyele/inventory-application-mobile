import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/invoice.dart';
import '../models/item.dart';
import '../models/party.dart';
import '../models/sales_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Raises an invoice for a credit sale.
///
/// The receipt editor's twin, and the same two shapes: standalone, where
/// issuing takes the stock off the shelf, or against a sales order, where the
/// lines are fixed to what that order already sent and no stock moves.
class InvoiceEditorPage extends StatefulWidget {
  const InvoiceEditorPage({super.key, this.salesOrderId});

  final String? salesOrderId;

  @override
  State<InvoiceEditorPage> createState() => _InvoiceEditorPageState();
}

class _InvoiceEditorPageState extends State<InvoiceEditorPage> {
  /// The terms a shop actually offers, plus a way out of the list.
  static const _termOptions = <int?>[0, 7, 14, 30, 60, null];

  SalesOrder? _order;
  String? _customerId;
  int? _termDays = 30;
  DateTime? _dueAt;
  final _discount = TextEditingController();
  final _notes = TextEditingController();
  final _lines = <_LineDraft>[];
  bool _initialised = false;

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
      controller.invoiceLinesForSalesOrder(order).map(_LineDraft.fromLine),
    );
  }

  @override
  void dispose() {
    _discount.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  InventoryController get _controller => context.read<InventoryController>();

  bool get _fromSale => _order != null;

  List<InvoiceLine> _buildLines() => [
    for (final line in _lines)
      if (line.itemId != null && line.quantity > 0)
        InvoiceLine(
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

  DateTime? get _resolvedDue {
    if (_termDays == null) return _dueAt;
    if (_termDays == 0) return DateTime.now();
    return DateTime.now().add(Duration(days: _termDays!));
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now.add(const Duration(days: 30)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
      helpText: 'Payment due',
    );
    if (picked != null) setState(() => _dueAt = picked);
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
    if (_customerId == null && !_fromSale) {
      _notify(
        'A credit sale needs a customer — that is who owes the money.',
        tone: MessageTone.warning,
      );
      return;
    }

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

    final invoice = _controller.issueInvoice(
      salesOrderId: _order?.id,
      customerId: _customerId,
      lines: lines,
      discount: _billDiscount,
      dueAt: _resolvedDue,
      terms: _termsLabel,
      notes: _notes.text.trim(),
    );

    if (invoice == null) {
      _notify(
        'Nothing could be invoiced — check the quantities.',
        tone: MessageTone.failure,
      );
      return;
    }
    // Awaited: routing away takes the dialog down with the page it sits on.
    await _notify('${invoice.reference} issued');
    if (!mounted) return;
    context.go('/invoices/${invoice.id}');
  }

  String get _termsLabel => switch (_termDays) {
    0 => 'Due on receipt',
    null => _dueAt == null ? '' : 'Due ${dayLabel(_dueAt!)}',
    final days => '$days days net',
  };

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
            onPressed: () => context.go('/invoices'),
            child: const Text('Back to invoices'),
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
              'An invoice bills for goods the customer has actually received. '
              'Send stock against ${_order!.reference} first, then invoice '
              'for what went out.',
          action: FilledButton(
            onPressed: () => context.go('/sales-orders/${_order!.id}'),
            child: const Text('Back to the sale'),
          ),
        ),
      );
    }

    final tier = controller.priceTierFor(_customerId);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: _fromSale
                  ? 'Invoice for ${_order!.reference}'
                  : 'New Invoice',
              subtitle: _fromSale
                  ? 'Bills what that sale has already sent'
                  : 'Goods go out now, payment comes later',
              showBack: true,
            ),
            SectionCard(
              title: 'Bill to',
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
                      const DropdownMenuItem(child: Text('Choose a customer')),
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
                          }),
                  ),
                  const SizedBox(height: Insets.md),
                  DropdownButtonFormField<int?>(
                    initialValue: _termDays,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Payment terms',
                    ),
                    items: [
                      for (final days in _termOptions)
                        DropdownMenuItem(
                          value: days,
                          child: Text(switch (days) {
                            0 => 'Due on receipt',
                            null => 'Pick a date',
                            final d => '$d days net',
                          }),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _termDays = value;
                      if (value == null && _dueAt == null) {
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _pickDue(),
                        );
                      }
                    }),
                  ),
                  if (_termDays == null) ...[
                    const SizedBox(height: Insets.md),
                    InkWell(
                      onTap: _pickDue,
                      borderRadius: BorderRadius.circular(Radii.control),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Due date',
                          suffixIcon: Icon(
                            Icons.calendar_today_outlined,
                            size: 18,
                          ),
                        ),
                        child: Text(
                          _dueAt == null ? 'Not set' : dayLabel(_dueAt!),
                          style: TextStyle(
                            color: _dueAt == null ? p.inkMuted : p.ink,
                          ),
                        ),
                      ),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _resolvedDue == null
                              ? ''
                              : 'Due ${dayLabel(_resolvedDue!)}',
                          style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                        ),
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
                      onChanged: () => setState(() {}),
                      onRemove: () => setState(() {
                        _lines.removeAt(index).dispose();
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
              title: 'Totals',
              child: Column(
                children: [
                  TextField(
                    controller: _discount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText:
                          'Discount off the bill (${currencySymbol(currency)})',
                      isDense: true,
                    ),
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
                    label: 'Invoice total',
                    value: money(_total, currency),
                    strong: true,
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
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text('Issue invoice · ${money(_total, currency)}'),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              _fromSale
                  ? 'This bills for the sale only. The stock left the shelf '
                        'when the order was sent.'
                  : 'Issuing takes the stock off the shelf now. Record the '
                        'payment later and a receipt is issued for it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: p.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

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
  const _Total({required this.label, required this.value, this.strong = false});

  final String label;
  final String value;
  final bool strong;

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
              color: strong ? p.ink : p.inkSecondary,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: strong ? 17 : 13.5,
              fontWeight: FontWeight.w700,
              color: p.ink,
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

  factory _LineDraft.fromLine(InvoiceLine line) => _LineDraft(
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
