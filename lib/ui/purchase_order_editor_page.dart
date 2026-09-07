import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../models/purchase_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Raises or edits a draft order. Once placed, an order is a record of what
/// was agreed, so this screen refuses to open on anything but a draft.
class PurchaseOrderEditorPage extends StatefulWidget {
  const PurchaseOrderEditorPage({super.key, this.orderId});

  final String? orderId;

  @override
  State<PurchaseOrderEditorPage> createState() =>
      _PurchaseOrderEditorPageState();
}

class _PurchaseOrderEditorPageState extends State<PurchaseOrderEditorPage> {
  PurchaseOrder? _existing;
  String? _supplierId;
  DateTime? _expectedAt;
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
        : controller.purchaseOrderById(widget.orderId!);
    _existing = existing;
    if (existing == null) return;

    _supplierId = existing.supplierId;
    _expectedAt = existing.expectedAt;
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

  List<PurchaseOrderLine> _buildLines() => [
    for (final line in _lines)
      if (line.itemId != null && line.quantity > 0)
        PurchaseOrderLine(
          id: line.id,
          itemId: line.itemId!,
          itemName: line.itemName,
          quantityOrdered: line.quantity,
          quantityReceived: line.received,
          unitCost: line.cost,
        ),
  ];

  void _save({required bool place}) {
    final controller = context.read<InventoryController>();
    final lines = _buildLines();
    if (lines.isEmpty) {
      _notify('Add at least one line with an item and a quantity.');
      return;
    }

    final existing = _existing;
    final id = existing == null
        ? controller
              .createPurchaseOrder(
                supplierId: _supplierId,
                expectedAt: _expectedAt,
                notes: _notes.text.trim(),
                lines: lines,
              )
              .id
        : existing.id;

    if (existing != null) {
      controller.updatePurchaseOrder(
        id,
        supplierId: _supplierId,
        clearSupplier: _supplierId == null,
        expectedAt: _expectedAt,
        clearExpectedAt: _expectedAt == null,
        notes: _notes.text.trim(),
        lines: lines,
      );
    }

    if (place) controller.placePurchaseOrder(id);
    _notify(place ? 'Order placed' : 'Draft saved');
    context.go('/purchase-orders/$id');
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickExpected() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expectedAt ?? now.add(const Duration(days: 7)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
      helpText: 'Expected delivery',
    );
    if (picked != null) setState(() => _expectedAt = picked);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    if (widget.orderId != null &&
        (_existing == null || !_existing!.status.isEditable)) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'This order cannot be edited',
          body:
              'Only drafts can be changed. A placed order is a record of what '
              'was agreed with the supplier.',
          action: FilledButton(
            onPressed: () => context.go('/purchase-orders'),
            child: const Text('Back to orders'),
          ),
        ),
      );
    }

    final total = _buildLines().fold(0.0, (sum, l) => sum + l.lineTotal);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: _existing == null
                  ? 'New Order'
                  : 'Edit ${_existing!.reference}',
              subtitle: 'Nothing moves in stock until the order is received',
              showBack: true,
            ),
            SectionCard(
              title: 'Order',
              child: Column(
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _supplierId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Supplier'),
                    items: [
                      const DropdownMenuItem(child: Text('None')),
                      for (final supplier in controller.suppliers)
                        DropdownMenuItem(
                          value: supplier.id,
                          child: Text(supplier.name),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _supplierId = value;
                      // Re-default the date from the new supplier's lead time.
                      final lead = controller.supplierById(value)?.leadTimeDays;
                      if (lead != null && lead > 0) {
                        _expectedAt = DateTime.now().add(Duration(days: lead));
                      }
                    }),
                  ),
                  const SizedBox(height: Insets.md),
                  InkWell(
                    onTap: _pickExpected,
                    borderRadius: BorderRadius.circular(Radii.control),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Expected delivery',
                        suffixIcon: _expectedAt == null
                            ? const Icon(
                                Icons.calendar_today_outlined,
                                size: 18,
                              )
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () =>
                                    setState(() => _expectedAt = null),
                              ),
                      ),
                      child: Text(
                        _expectedAt == null
                            ? 'Not set'
                            : dayLabel(_expectedAt!),
                        style: TextStyle(
                          color: _expectedAt == null ? p.inkMuted : p.ink,
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
                        'No lines yet. Add the items you are ordering.',
                        style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                      ),
                    ),
                  for (final (index, line) in _lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineEditor(
                      line: line,
                      items: controller.items,
                      currency: currency,
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _save(place: false),
                    child: const Text('Save draft'),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _save(place: true),
                    child: const Text('Place order'),
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
    this.received = 0,
    String quantity = '',
    String cost = '',
  }) : quantityController = TextEditingController(text: quantity),
       costController = TextEditingController(text: cost);

  factory _LineDraft.empty() =>
      _LineDraft(id: UniqueKey().toString(), quantity: '1');

  factory _LineDraft.fromLine(PurchaseOrderLine line) => _LineDraft(
    id: line.id,
    itemId: line.itemId,
    itemName: line.itemName,
    received: line.quantityReceived,
    quantity: '${line.quantityOrdered}',
    cost: line.unitCost == 0 ? '' : '${line.unitCost}',
  );

  final String id;
  String? itemId;
  String itemName;
  final int received;
  final TextEditingController quantityController;
  final TextEditingController costController;

  int get quantity => int.tryParse(quantityController.text.trim()) ?? 0;
  double get cost => parseAmount(costController.text) ?? 0;
  double get lineTotal => quantity * cost;

  void dispose() {
    quantityController.dispose();
    costController.dispose();
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    required this.line,
    required this.items,
    required this.currency,
    required this.onChanged,
    required this.onRemove,
  });

  final _LineDraft line;
  final List<Item> items;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final known = items.any((i) => i.id == line.itemId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final itemField = DropdownButtonFormField<String>(
          initialValue: known ? line.itemId : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Item', isDense: true),
          items: [
            for (final item in items)
              DropdownMenuItem(value: item.id, child: Text(item.name)),
          ],
          onChanged: (value) {
            line.itemId = value;
            final picked = items.where((i) => i.id == value).firstOrNull;
            line.itemName = picked?.name ?? '';
            // Seed the cost from what the item currently costs, so the buyer
            // only types it when the price has changed.
            if (picked != null && line.costController.text.trim().isEmpty) {
              line.costController.text = picked.unitCost == 0
                  ? ''
                  : '${picked.unitCost}';
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
            helperText: line.received > 0
                ? '${number(line.received)} already received'
                : null,
          ),
        );

        final costField = TextField(
          controller: line.costController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: 'Unit cost (${currencySymbol(currency)})',
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
                  Expanded(child: costField),
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
            Expanded(flex: 3, child: costField),
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
