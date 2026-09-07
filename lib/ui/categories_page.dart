import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/category_colors.dart';
import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';

/// Categories are stored on items by name, so this page is a view over the
/// settings list plus a live count of the items using each one. Renaming a
/// category rewrites the items that referenced it, so no item is orphaned.
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final settings = controller.settings;
    final p = context.palette;

    final counts = <String, int>{for (final c in settings.categories) c: 0};
    for (final item in controller.items) {
      if (item.category.isEmpty) continue;
      counts[item.category] = (counts[item.category] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort();

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Categories',
              subtitle: 'Group items and colour-code them across the app',
              actions: [
                FilledButton.icon(
                  onPressed: () => _edit(context, controller, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Category'),
                ),
              ],
            ),
            if (names.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.sell_outlined,
                  title: 'No categories yet',
                  body:
                      'Categories let you filter items and see where your '
                      'stock value sits.',
                  action: FilledButton.icon(
                    onPressed: () => _edit(context, controller, null),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Category'),
                  ),
                ),
              )
            else
              for (final name in names) ...[
                _CategoryRow(
                  name: name,
                  count: counts[name]!,
                  color: settings.colorFor(name),
                  onEdit: () => _edit(context, controller, name),
                  onDelete: () =>
                      _confirmDelete(context, controller, name, counts[name]!),
                  onOpen: () => context.go('/items?category=$name'),
                ),
                const SizedBox(height: Insets.md),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    InventoryController controller,
    String? existing,
  ) async {
    final settings = controller.settings;
    final result = await showDialog<({String name, int swatch})>(
      context: context,
      builder: (dialogContext) => _CategoryDialog(
        initialName: existing ?? '',
        initialSwatch: existing == null ? 0 : settings.swatchIndexFor(existing),
        taken: settings.categories
            .where((c) => c != existing)
            .map((c) => c.toLowerCase())
            .toSet(),
      ),
    );
    if (result == null) return;

    if (existing == null) {
      controller.addCategory(result.name, result.swatch);
    } else {
      controller.renameCategory(existing, result.name, result.swatch);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    InventoryController controller,
    String name,
    int count,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete category'),
        content: Text(
          count == 0
              ? 'Remove "$name" from the category list?'
              : 'Remove "$name"? The ${count == 1 ? '1 item' : '$count items'} '
                    'using it will keep their stock but become uncategorised.',
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
    controller.deleteCategory(name);
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.name,
    required this.count,
    required this.color,
    required this.onEdit,
    required this.onDelete,
    required this.onOpen,
  });

  final String name;
  final int count;
  final Color color;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          onTap: count == 0 ? null : onOpen,
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(Radii.tile),
                  ),
                  child: Center(
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Insets.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: p.ink,
                        ),
                      ),
                      Text(
                        count == 1 ? '1 item' : '${number(count)} items',
                        style: TextStyle(fontSize: 13, color: p.inkMuted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit $name',
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Delete $name',
                  style: IconButton.styleFrom(foregroundColor: p.critical),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({
    required this.initialName,
    required this.initialSwatch,
    required this.taken,
  });

  final String initialName;
  final int initialSwatch;
  final Set<String> taken;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late int _swatch = widget.initialSwatch;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the category a name.');
      return;
    }
    if (widget.taken.contains(name.toLowerCase())) {
      setState(() => _error = 'That category already exists.');
      return;
    }
    Navigator.of(context).pop((name: name, swatch: _swatch));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initialName.isEmpty;

    return AlertDialog(
      title: Text(isNew ? 'Add Category' : 'Edit Category'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Electronics',
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: Insets.xl),
            Text('Color', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final (index, color) in categorySwatches.indexed)
                  _Swatch(
                    color: color,
                    selected: index == _swatch,
                    onTap: () => setState(() => _swatch = index),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(isNew ? 'Add Category' : 'Save'),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: 'Colour swatch',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 38,
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? color : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: selected
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }
}
