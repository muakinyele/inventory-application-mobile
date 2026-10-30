import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../models/party.dart';
import '../models/sales_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Raises or edits a draft sale. Once confirmed, a sale is a record of what
/// was quoted, so this screen refuses to open on anything but a draft.
class SalesOrderEditorPage extends StatefulWidget {
  const SalesOrderEditorPage({super.key, this.orderId});

  final String? orderId;

  @override
  State<SalesOrderEditorPage> createState() => _SalesOrderEditorPageState();
}

class _SalesOrderEditorPageState extends State<SalesOrderEditorPage> {
  SalesOrder? _existing;
  String? _customerId;
  DateTime? _dueAt;
  final _notes = TextEditingController();
  final _lines = <_LineDraft>[];
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;

    final controller = context.read<InventoryController>();
    final existing = widget.orderId == null
        ? null
        : controller.salesOrderById(widget.orderId!);
    _existing = existing;
    if (existing == null) return;

    _customerId = existing.customerId;
    _dueAt = existing.dueAt;
    _notes.text = existing.notes;
    _lines.addAll(existing.lines.map(_LineDraft.fromLine));
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  List<SalesOrderLine> _buildLines() => [
    for (final line in _lines)
      if (line.itemId != null && line.quantity > 0)
        SalesOrderLine(
          id: line.id,
          itemId: line.itemId!,
          itemName: line.itemName,
          quantityOrdered: line.quantity,
          quantityFulfilled: line.fulfilled,
          unitPrice: line.price,
          costOfGoods: line.costOfGoods,
        ),
  ];

  Future<void> _save({required bool confirm}) async {
    final controller = context.read<InventoryController>();
    final lines = _buildLines();
    if (lines.isEmpty) {
      _notify(
        'Add at least one line with an item and a quantity.',
        tone: MessageTone.warning,
      );
      return;
    }

    final existing = _existing;

    // An order cannot promise stock that is not there, new or edited. The
    // server refuses it too; checked here so the reason comes before saving.
    {
      final short = controller.outOfStockReasons(lines);
      if (short.isNotEmpty) {
        await _notify(
          'This order asks for more than is in stock. ${short.join('; ')}. '
          'Lower the quantities or restock first.',
          tone: MessageTone.failure,
        );
        return;
      }
    }

    final id = existing == null
        ? (await controller.createSalesOrder(
            customerId: _customerId,
            dueAt: _dueAt,
            notes: _notes.text.trim(),
            lines: lines,
          )).id
        : existing.id;

    if (existing != null) {
      final refused = await controller.updateSalesOrder(
        id,
        customerId: _customerId,
        clearCustomer: _customerId == null,
        dueAt: _dueAt,
        clearDueAt: _dueAt == null,
        notes: _notes.text.trim(),
        lines: lines,
      );
      if (refused != null) {
        // Said here, with its reason; nothing was left half-saved.
        controller.clearWriteError();
        if (mounted) await _notify(refused, tone: MessageTone.failure);
        return;
      }
    }

    if (id.isEmpty) {
      // The server refused it; nothing was saved.
      final reason = controller.reasonFor(
        controller.lastWriteError,
        'The sale could not be saved.',
      );
      // Said here with its reason, so the "not saved" banner is not left up.
      controller.clearWriteError();
      await _notify(reason, tone: MessageTone.failure);
      return;
    }

    // A confirmed order being edited stays confirmed; only a draft is
    // confirmed from here.
    final confirming =
        confirm && (existing?.status ?? SalesStatus.draft) == SalesStatus.draft;
    final refused = confirming ? await controller.confirmSalesOrder(id) : null;
    if (refused != null) controller.clearWriteError();
    if (!mounted) return;
    // Awaited: routing away takes the dialog down with the page it sits on.
    await _notify(
      refused != null
          ? 'Saved as a draft, not confirmed. $refused'
          : (confirming
                ? 'Sale confirmed'
                : (existing != null && existing.status != SalesStatus.draft
                      ? 'Changes saved'
                      : 'Draft saved')),
      tone: refused != null ? MessageTone.warning : MessageTone.success,
    );
    if (!mounted) return;
    context.go('/sales-orders/$id');
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
      initialDate: _dueAt ?? now.add(const Duration(days: 3)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
      helpText: 'Promised date',
    );
    if (picked != null) setState(() => _dueAt = picked);
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

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    final blocked = _existing == null
        ? null
        : controller.editBlockedReason(_existing!);
    if (widget.orderId != null && (_existing == null || blocked != null)) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'This sale cannot be edited',
          body:
              blocked ??
              'It may have been deleted. A sale can be changed until it is '
                  'paid for, invoiced or receipted.',
          action: FilledButton(
            onPressed: () => context.go('/sales-orders'),
            child: const Text('Back to sales'),
          ),
        ),
      );
    }

    final tier = controller.priceTierFor(_customerId);
    final total = _buildLines().fold(0.0, (sum, l) => sum + l.lineTotal);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: _existing == null
                  ? 'New Sale'
                  : 'Edit ${_existing!.reference}',
              subtitle:
                  'Nothing leaves stock until it is receipted or invoiced',
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
                      helperText: 'Priced at ${tier.label.toLowerCase()} rates',
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
                    onChanged: (value) => setState(() {
                      _customerId = value;
                      _reprice(
                        controller.items,
                        controller.priceTierFor(value),
                      );
                    }),
                  ),
                  const SizedBox(height: Insets.md),
                  InkWell(
                    onTap: _pickDue,
                    borderRadius: BorderRadius.circular(Radii.control),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Promised date',
                        suffixIcon: _dueAt == null
                            ? const Icon(
                                Icons.calendar_today_outlined,
                                size: 18,
                              )
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () => setState(() => _dueAt = null),
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
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              trailing: Text(
                money(total, currency),
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
                        'No lines yet. Add what the customer is buying.',
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
                      onChanged: () => setState(() {}),
                      onRemove: () => setState(() {
                        _lines.removeAt(index).dispose();
                      }),
                    ),
                  ],
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
              ),
            ),
            const SizedBox(height: Insets.xl),
            // A confirmed sale is edited in place and stays confirmed; only a
            // new sale or a draft has the choice of confirming.
            if (_existing != null && _existing!.status != SalesStatus.draft)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _save(confirm: false),
                  child: const Text('Save changes'),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _save(confirm: false),
                      child: const Text('Save draft'),
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _save(confirm: true),
                      child: const Text('Confirm sale'),
                    ),
                  ),
                ],
              ),
          ],
        ),
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
    this.fulfilled = 0,
    this.costOfGoods = 0,
    String quantity = '',
    String price = '',
  }) : quantityController = TextEditingController(text: quantity),
       priceController = TextEditingController(text: price);

  factory _LineDraft.empty() =>
      _LineDraft(id: UniqueKey().toString(), quantity: '1');

  factory _LineDraft.fromLine(SalesOrderLine line) => _LineDraft(
    id: line.id,
    itemId: line.itemId,
    itemName: line.itemName,
    fulfilled: line.quantityFulfilled,
    costOfGoods: line.costOfGoods,
    quantity: '${line.quantityOrdered}',
    price: line.unitPrice == 0 ? '' : '${line.unitPrice}',
  );

  final String id;
  String? itemId;
  String itemName;
  final int fulfilled;
  final double costOfGoods;
  final TextEditingController quantityController;
  final TextEditingController priceController;

  /// Set once the seller types a price, so re-tiering never overwrites a
  /// deliberate figure.
  bool priceEdited = false;

  int get quantity => int.tryParse(quantityController.text.trim()) ?? 0;
  double get price => parseAmount(priceController.text) ?? 0;
  double get lineTotal => quantity * price;

  void setPrice(double value) {
    priceController.text = value == 0 ? '' : '$value';
  }

  void dispose() {
    quantityController.dispose();
    priceController.dispose();
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    required this.line,
    required this.items,
    required this.currency,
    required this.tier,
    required this.onChanged,
    required this.onRemove,
  });

  final _LineDraft line;
  final List<Item> items;
  final String currency;
  final PriceTier tier;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final picked = items.where((i) => i.id == line.itemId).firstOrNull;
    final short = picked != null && line.quantity > picked.quantity;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final itemField = DropdownButtonFormField<String>(
          initialValue: picked == null ? null : line.itemId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Item', isDense: true),
          // Each item with what is in stock now, so the seller sees what can
          // be sold before picking it. An item with none cannot be picked: a
          // new order may not promise stock that is not there. One already on
          // this line stays selectable, so an existing draft still shows it.
          items: [
            for (final item in items)
              DropdownMenuItem(
                value: item.id,
                enabled: item.quantity > 0 || item.id == line.itemId,
                child: _ItemWithStock(item: item),
              ),
          ],
          onChanged: (value) {
            line.itemId = value;
            final chosen = items.where((i) => i.id == value).firstOrNull;
            line.itemName = chosen?.name ?? '';
            // Quote from the customer's tier unless the seller has already
            // typed a price of their own.
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
            helperText: switch ((line.fulfilled > 0, short)) {
              (true, _) => '${number(line.fulfilled)} already sent',
              (false, true) =>
                picked!.quantity <= 0
                    ? 'Out of stock'
                    : 'Only ${number(picked.quantity)} in stock',
              // What this line leaves on the shelf once it is billed.
              _ when picked != null =>
                '${number(picked.quantity)} in stock · '
                    '${number(picked.quantity - line.quantity)} left',
              _ => null,
            },
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

/// An item as the picker lists it: its name, and what is in stock now in its
/// own unit, or "Out of stock" in red.
class _ItemWithStock extends StatelessWidget {
  const _ItemWithStock({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final none = item.quantity <= 0;
    return Row(
      children: [
        Expanded(
          child: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: none ? p.inkMuted : null),
          ),
        ),
        const SizedBox(width: Insets.sm),
        Text(
          none
              ? 'Out of stock'
              : '${number(item.quantity)} ${item.unit} in stock',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: none ? p.critical : p.inkSecondary,
          ),
        ),
      ],
    );
  }
}
