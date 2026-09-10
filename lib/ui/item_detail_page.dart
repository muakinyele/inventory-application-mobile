import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/formatters.dart';
import '../core/palette.dart';
import '../core/theme.dart';
import '../models/item.dart';
import '../models/transfer.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/bin_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/item_thumb.dart';
import 'widgets/movement_tile.dart';
import 'widgets/section_card.dart';
import 'widgets/page_header.dart';
import 'widgets/status_chip.dart';

enum _Mode { stockIn, stockOut, count }

class ItemDetailPage extends StatelessWidget {
  const ItemDetailPage({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final item = controller.byId(itemId);

    if (item == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Item not found',
          body: 'It may have been deleted. Its history is still in Activity.',
          action: FilledButton(
            onPressed: () => context.go('/items'),
            child: const Text('Back to items'),
          ),
        ),
      );
    }

    final p = context.palette;
    final currency = controller.settings.currency;
    final history = controller.movements
        .where((m) => m.itemId == item.id)
        .take(30)
        .toList();
    final bins = controller.stockByLocation(item.id);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: item.name,
              subtitle: item.sku.isEmpty ? 'No SKU' : item.sku,
              showBack: true,
              actions: [
                FilledButton.icon(
                  onPressed: () => context.go('/items/${item.id}/edit'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
              ],
            ),
            SectionCard(
              child: Row(
                children: [
                  ItemThumb(item: item, size: 76),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              number(item.quantity),
                              style: TextStyle(
                                fontFamily: fontDisplay,
                                fontSize: 32,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                color: p.ink,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              item.unit,
                              style: TextStyle(fontSize: 13, color: p.inkMuted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        StatusChip(status: item.status),
                        const SizedBox(height: 6),
                        Text(
                          '${money(item.stockValue, currency)} at cost',
                          style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _openMode(context, item, _Mode.stockIn),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    label: const Text('Stock in'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openMode(context, item, _Mode.stockOut),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    label: const Text('Stock out'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  child: OutlinedButton(
                    onPressed: () => _openMode(context, item, _Mode.count),
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Tooltip(
                      message: 'Set counted quantity',
                      child: Icon(Icons.checklist, size: 18),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'Details',
              child: Column(
                children: [
                  _DetailGrid(
                    entries: [
                      ('Category', item.category),
                      ('Location', item.location),
                      (
                        'Reorder level',
                        '${number(item.reorderLevel)} ${item.unit}',
                      ),
                      ('Supplier', controller.supplierNameFor(item)),
                      (
                        'Units per pack',
                        item.unitsPerPack <= 1
                            ? '—'
                            : '${number(item.unitsPerPack)} per pack',
                      ),
                      ('Unit cost', money(item.unitCost, currency)),
                      (
                        'Retailer sales price',
                        item.retailerPrice > 0
                            ? money(item.retailerPrice, currency)
                            : '',
                      ),
                      (
                        'Distributor sales price',
                        item.distributorPrice > 0
                            ? money(item.distributorPrice, currency)
                            : '',
                      ),
                      ('Barcode', item.barcode),
                      ('Updated', relativeTime(item.updatedAt)),
                    ],
                  ),
                  if (item.notes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Divider(color: p.line, height: 1),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        item.notes,
                        style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (bins.length > 1) ...[
              const SizedBox(height: 14),
              SectionCard(
                title: 'Where it is',
                child: Column(
                  children: [
                    for (final (index, bin) in bins.entries.indexed) ...[
                      if (index > 0) const SizedBox(height: 10),
                      BinBar(
                        location: bin.key,
                        quantity: bin.value,
                        total: item.quantity,
                        trailing: '${number(bin.value)} ${item.unit}',
                        badge: stockBin(item.location) == bin.key
                            ? 'Home'
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            SectionCard(
              title: 'History',
              child: history.isEmpty
                  ? Text(
                      'No movements recorded for this item.',
                      style: TextStyle(color: p.inkSecondary),
                    )
                  : Column(
                      children: [
                        for (final m in history) ...[
                          if (m != history.first)
                            Divider(color: p.line, height: 1),
                          MovementTile(
                            movement: m,
                            title: m.note.isEmpty ? 'Updated' : m.note,
                            subtitle:
                                '${dateTimeLabel(m.at)} · ${number(m.before)} → ${number(m.after)}',
                            showBalance: false,
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _confirmDelete(context, item),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.critical,
                backgroundColor: p.criticalWash,
                side: BorderSide(color: p.critical.withValues(alpha: 0.4)),
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete item'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMode(BuildContext context, Item item, _Mode mode) async {
    final controller = context.read<InventoryController>();

    final result = await showModalBottomSheet<(int, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StockSheet(item: item, mode: mode),
    );
    if (result == null) return;

    final (amount, note) = result;

    if (mode == _Mode.count) {
      controller.setStock(
        item.id,
        amount,
        note: note.isEmpty ? 'Stocktake' : note,
      );
      if (!context.mounted) return;
      await showAppMessage(
        context,
        '${item.name} counted at ${number(amount)} ${item.unit}',
      );
      return;
    }

    final delta = mode == _Mode.stockIn ? amount : -amount;
    controller.adjustStock(
      item.id,
      delta,
      note: note.isEmpty
          ? (mode == _Mode.stockIn ? 'Stock received' : 'Stock issued')
          : note,
    );
    if (!context.mounted) return;
    await showAppMessage(
      context,
      '${item.name}: ${signed(delta)} ${item.unit}',
      action: MessageAction(
        label: 'Undo',
        onPressed: () => controller.adjustStock(item.id, -delta, note: 'Undo'),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Item item) async {
    final controller = context.read<InventoryController>();
    final router = GoRouter.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete item'),
        content: Text(
          'Remove ${item.name} from the catalogue? Its movement history is '
          'kept in Activity.',
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
    controller.deleteItem(item.id);
    // Said before routing away: this page is about to be replaced, and a
    // dialog goes down with the page it was opened over.
    if (context.mounted) await showAppMessage(context, '${item.name} deleted');
    router.go('/items');
  }
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.entries});

  final List<(String, String)> entries;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 4 : 2;
        final gap = 14.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: 12,
          children: [
            for (final (label, value) in entries)
              SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 11.5, color: p.inkMuted),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value.isEmpty ? '—' : value,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Quantity entry for stock in / out / stocktake. Pops `(amount, note)`.
class _StockSheet extends StatefulWidget {
  const _StockSheet({required this.item, required this.mode});

  final Item item;
  final _Mode mode;

  @override
  State<_StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends State<_StockSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.mode == _Mode.count ? '${widget.item.quantity}' : '',
  );
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _parsed {
    final value = int.tryParse(_amount.text.trim());
    if (value == null || value < 0) return null;
    return value;
  }

  void _bump(int by) {
    final current = int.tryParse(_amount.text.trim()) ?? 0;
    setState(() => _amount.text = '${(current + by).clamp(0, 1 << 31)}');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = switch (widget.mode) {
      _Mode.stockIn => 'Stock in',
      _Mode.stockOut => 'Stock out',
      _Mode.count => 'Set counted quantity',
    };
    final amount = _parsed;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${widget.item.name} · currently ${number(widget.item.quantity)} ${widget.item.unit}',
                style: TextStyle(fontSize: 13, color: p.inkSecondary),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _StepButton(icon: Icons.remove, onTap: () => _bump(-1)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      autofocus: true,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                      decoration: const InputDecoration(hintText: '0'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StepButton(icon: Icons.add, onTap: () => _bump(1)),
                ],
              ),
              if (widget.mode != _Mode.count) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final n in const [5, 10, 25, 50]) ...[
                      if (n != 5) const SizedBox(width: 7),
                      ActionChip(
                        label: Text('+$n'),
                        onPressed: () => _bump(n),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                  labelText: 'Note (optional)',
                  hintText: widget.mode == _Mode.stockIn
                      ? 'e.g. PO-2291 received'
                      : 'e.g. Counter sale',
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: amount == null
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop((amount, _note.text.trim())),
                child: Text(
                  widget.mode == _Mode.count ? 'Save count' : 'Confirm',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.surfaceSunken,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(width: 48, height: 48, child: Icon(icon, color: p.ink)),
      ),
    );
  }
}
