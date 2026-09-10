import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/transfer.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Records a move of stock between two locations. A transfer applies the
/// moment it is saved, so there is no draft — the form only ever describes
/// something that is about to happen once.
class TransferEditorPage extends StatefulWidget {
  const TransferEditorPage({super.key});

  @override
  State<TransferEditorPage> createState() => _TransferEditorPageState();
}

class _TransferEditorPageState extends State<TransferEditorPage> {
  String? _from;
  String? _to;
  final _notes = TextEditingController();
  final _lines = <_LineDraft>[];
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;

    // Default the source to wherever the most stock is sitting, which is the
    // place a transfer nearly always starts from.
    final controller = context.read<InventoryController>();
    final busiest = controller.unitsByLocation.keys.firstOrNull;
    _from = busiest;
    _lines.add(_LineDraft.empty());
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final controller = context.read<InventoryController>();
    final from = _from;
    final to = _to;

    if (from == null || to == null) {
      _notify(
        'Pick where the stock is moving from and to.',
        tone: MessageTone.warning,
      );
      return;
    }
    if (from == to) {
      _notify(
        'A transfer needs two different locations.',
        tone: MessageTone.warning,
      );
      return;
    }

    final lines = [
      for (final line in _lines)
        if (line.itemId != null && line.quantity > 0)
          TransferLine(
            id: line.id,
            itemId: line.itemId!,
            itemName: line.itemName,
            quantity: line.quantity,
          ),
    ];
    if (lines.isEmpty) {
      _notify(
        'Add at least one item with a quantity.',
        tone: MessageTone.warning,
      );
      return;
    }

    final transfer = controller.recordTransfer(
      fromLocation: from,
      toLocation: to,
      lines: lines,
      notes: _notes.text.trim(),
    );
    if (transfer == null) {
      _notify(
        'Nothing to move — $from is not holding any of those items.',
        tone: MessageTone.warning,
      );
      return;
    }

    final moved = transfer.units;
    final asked = lines.fold(0, (sum, l) => sum + l.quantity);
    // Awaited: routing away takes the dialog down with the page it sits on.
    await _notify(
      moved < asked
          ? '${transfer.reference}: moved $moved of $asked — '
                '$from did not hold the rest'
          : '${transfer.reference}: moved $moved to $to',
      tone: moved < asked ? MessageTone.warning : MessageTone.success,
    );
    if (!mounted) return;
    context.go('/transfers');
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final p = context.palette;
    final locations = controller.transferLocations;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            const PageHeader(
              title: 'Move Stock',
              subtitle:
                  'The total on hand does not change — only where it is sitting',
              showBack: true,
            ),
            SectionCard(
              title: 'Route',
              child: Column(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final from = _LocationField(
                        label: 'From',
                        value: _from,
                        options: locations,
                        onChanged: (value) => setState(() => _from = value),
                      );
                      final to = _LocationField(
                        label: 'To',
                        value: _to,
                        options: locations,
                        onChanged: (value) => setState(() => _to = value),
                      );
                      if (constraints.maxWidth < 560) {
                        return Column(
                          children: [
                            from,
                            const SizedBox(height: Insets.md),
                            to,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: from),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Insets.md,
                            ),
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 18,
                              color: p.inkMuted,
                            ),
                          ),
                          Expanded(child: to),
                        ],
                      );
                    },
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
              title: 'Items',
              trailing: Text(
                '${number(_lines.fold(0, (sum, l) => sum + l.quantity))} units',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              child: Column(
                children: [
                  for (final (index, line) in _lines.indexed) ...[
                    if (index > 0) Divider(color: p.line, height: Insets.xl),
                    _LineEditor(
                      line: line,
                      controller: controller,
                      from: _from,
                      onChanged: () => setState(() {}),
                      onRemove: _lines.length == 1
                          ? null
                          : () => setState(() {
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
                      label: const Text('Add item'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.xl),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Move stock'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A location picker that also accepts a name that does not exist yet, so
/// stock can be moved somewhere new without a trip to Settings first.
class _LocationField extends StatelessWidget {
  const _LocationField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: value ?? ''),
      optionsBuilder: (input) {
        final query = input.text.trim().toLowerCase();
        if (query.isEmpty) return options;
        return options.where((o) => o.toLowerCase().contains(query));
      },
      onSelected: onChanged,
      fieldViewBuilder: (context, textController, focusNode, onSubmit) {
        return TextField(
          controller: textController,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.expand_more_rounded, size: 20),
          ),
          onChanged: (text) {
            final trimmed = text.trim();
            onChanged(trimmed.isEmpty ? null : trimmed);
          },
        );
      },
    );
  }
}

class _LineDraft {
  _LineDraft({required this.id, String quantity = ''})
    : quantityController = TextEditingController(text: quantity);

  factory _LineDraft.empty() => _LineDraft(id: UniqueKey().toString());

  final String id;
  String? itemId;
  String itemName = '';
  final TextEditingController quantityController;

  int get quantity => int.tryParse(quantityController.text.trim()) ?? 0;

  void dispose() => quantityController.dispose();
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    required this.line,
    required this.controller,
    required this.from,
    required this.onChanged,
    required this.onRemove,
  });

  final _LineDraft line;
  final InventoryController controller;
  final String? from;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    // Only what the source location is actually holding can be moved, so the
    // picker never offers an item that is not there.
    final available = from == null
        ? controller.items
        : controller.items
              .where((i) => controller.onHandAt(i.id, from!) > 0)
              .toList();
    final known = available.any((i) => i.id == line.itemId);
    final onHand = line.itemId == null || from == null
        ? null
        : controller.onHandAt(line.itemId!, from!);
    final over = onHand != null && line.quantity > onHand;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final itemField = DropdownButtonFormField<String>(
          initialValue: known ? line.itemId : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Item',
            isDense: true,
            helperText: from == null
                ? 'Pick a source location first'
                : available.isEmpty
                ? 'Nothing is held at $from'
                : null,
          ),
          items: [
            for (final item in available)
              DropdownMenuItem(
                value: item.id,
                child: Text(
                  '${item.name}  ·  '
                  '${number(controller.onHandAt(item.id, from ?? ''))} here',
                ),
              ),
          ],
          onChanged: (value) {
            line.itemId = value;
            line.itemName =
                available.where((i) => i.id == value).firstOrNull?.name ?? '';
            // Default to moving the whole bin, which is the common case.
            if (value != null && line.quantityController.text.trim().isEmpty) {
              line.quantityController.text =
                  '${controller.onHandAt(value, from ?? '')}';
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
            helperText: onHand == null
                ? null
                : over
                ? 'Only ${number(onHand)} at $from'
                : '${number(onHand)} available',
            helperStyle: over
                ? TextStyle(color: p.warningText, fontWeight: FontWeight.w600)
                : null,
          ),
        );

        final remove = IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline, size: 20),
          tooltip: 'Remove item',
          style: IconButton.styleFrom(foregroundColor: p.critical),
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
                  remove,
                ],
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: itemField),
            const SizedBox(width: Insets.sm),
            Expanded(flex: 3, child: quantityField),
            remove,
          ],
        );
      },
    );
  }
}
