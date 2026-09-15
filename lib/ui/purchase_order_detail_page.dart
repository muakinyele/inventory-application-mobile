import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/purchase_order.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';
import 'widgets/status_pill.dart';

class PurchaseOrderDetailPage extends StatelessWidget {
  const PurchaseOrderDetailPage({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final order = controller.purchaseOrderById(orderId);
    final p = context.palette;

    if (order == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Order not found',
          body: 'It may have been deleted.',
          action: FilledButton(
            onPressed: () => context.go('/purchase-orders'),
            child: const Text('Back to orders'),
          ),
        ),
      );
    }

    final currency = controller.settings.currency;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: order.reference,
              subtitle: order.supplierName.isEmpty
                  ? 'No supplier'
                  : order.supplierName,
              showBack: true,
              actions: [
                if (order.status.isEditable)
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.go('/purchase-orders/${order.id}/edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                if (order.status == PurchaseStatus.draft)
                  FilledButton.icon(
                    onPressed: () => controller.placePurchaseOrder(order.id),
                    icon: const Icon(Icons.send_outlined, size: 18),
                    label: const Text('Place order'),
                  ),
                if (order.status.isOpen)
                  FilledButton.icon(
                    onPressed: () => _receive(context, controller, order),
                    icon: const Icon(Icons.inventory_outlined, size: 18),
                    label: const Text('Receive'),
                  ),
              ],
            ),
            SectionCard(
              child: Wrap(
                spacing: Insets.section,
                runSpacing: Insets.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PurchaseStatusPill(
                    status: order.status,
                    overdue: order.isOverdue,
                  ),
                  _Fact(
                    label: 'Ordered',
                    value: order.orderedAt == null
                        ? '—'
                        : dayLabel(order.orderedAt!),
                  ),
                  _Fact(
                    label: 'Expected',
                    value: order.expectedAt == null
                        ? '—'
                        : dayLabel(order.expectedAt!),
                  ),
                  _Fact(
                    label: 'Received',
                    value:
                        '${number(order.unitsReceived)} of '
                        '${number(order.unitsOrdered)}',
                  ),
                  _Fact(label: 'Total', value: money(order.total, currency)),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final (index, line) in order.lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineRow(line: line, currency: currency),
                  ],
                  if (order.lines.isEmpty)
                    Text(
                      'This order has no lines.',
                      style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                    ),
                ],
              ),
            ),
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
                if (order.status != PurchaseStatus.received &&
                    order.status != PurchaseStatus.cancelled)
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
                      label: const Text('Cancel order'),
                    ),
                  ),
                if (order.unitsReceived == 0) ...[
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

  Future<void> _receive(
    BuildContext context,
    InventoryController controller,
    PurchaseOrder order,
  ) async {
    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReceiveSheet(order: order),
    );
    if (result == null || result.isEmpty) return;

    final moved = await controller.receivePurchaseOrder(order.id, result);
    if (!context.mounted) return;
    await showAppMessage(
      context,
      moved == 0
          ? 'Nothing to receive'
          : 'Booked in ${moved == 1 ? '1 line' : '$moved lines'}',
      tone: moved == 0 ? MessageTone.warning : MessageTone.success,
    );
  }

  Future<void> _cancel(
    BuildContext context,
    InventoryController controller,
    PurchaseOrder order,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel order'),
        content: Text(
          order.unitsReceived > 0
              ? 'Cancel ${order.reference}? Stock already received stays '
                    'booked in; only the outstanding balance is dropped.'
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
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.cancelPurchaseOrder(order.id);
  }

  Future<void> _delete(
    BuildContext context,
    InventoryController controller,
    PurchaseOrder order,
  ) async {
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete order'),
        content: Text(
          'Remove ${order.reference}? Nothing has been received against it, '
          'so no stock is affected.',
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
    controller.deletePurchaseOrder(order.id);
    router.go('/purchase-orders');
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

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
            color: p.ink,
          ),
        ),
      ],
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.currency});

  final PurchaseOrderLine line;
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
                '${number(line.quantityOrdered)} ordered · '
                '${number(line.quantityReceived)} received'
                '${line.outstanding > 0 ? ' · ${number(line.outstanding)} outstanding' : ''}',
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
              money(line.lineTotal, currency),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: p.ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '${money(line.unitCost, currency)} each',
              style: TextStyle(fontSize: 12, color: p.inkMuted),
            ),
          ],
        ),
      ],
    );
  }
}

/// Asks how much of each outstanding line has arrived, pre-filled with the
/// full balance since receiving everything is the common case.
class _ReceiveSheet extends StatefulWidget {
  const _ReceiveSheet({required this.order});

  final PurchaseOrder order;

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final line in widget.order.lines)
      if (line.outstanding > 0)
        line.id: TextEditingController(text: '${line.outstanding}'),
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
                'Receive ${widget.order.reference}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Enter what actually arrived. Anything left stays outstanding.',
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
                            '${number(line.outstanding)} outstanding',
                            style: TextStyle(fontSize: 12.5, color: p.inkMuted),
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
                child: const Text('Book in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
