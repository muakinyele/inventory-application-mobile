import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../models/party.dart';
import '../state/inventory_controller.dart';
import 'widgets/contact_card.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';

class SuppliersPage extends StatelessWidget {
  const SuppliersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final suppliers = controller.suppliers;
    final p = context.palette;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Suppliers',
              subtitle: 'Who you buy from, and how long they take',
              actions: [
                FilledButton.icon(
                  onPressed: () => _edit(context, controller, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Supplier'),
                ),
              ],
            ),
            if (suppliers.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No suppliers yet',
                  body:
                      'Adding suppliers lets you track lead times and see '
                      'which items come from where.',
                  action: FilledButton.icon(
                    onPressed: () => _edit(context, controller, null),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Supplier'),
                  ),
                ),
              )
            else
              for (final supplier in suppliers) ...[
                ContactCard(
                  name: supplier.name,
                  subtitle: [
                    if (supplier.contactName.isNotEmpty) supplier.contactName,
                    if (supplier.phone.isNotEmpty) supplier.phone,
                    if (supplier.email.isNotEmpty) supplier.email,
                  ].join(' · '),
                  facts: [
                    (
                      'Items supplied',
                      number(controller.itemCountForSupplier(supplier.id)),
                    ),
                    (
                      'Lead time',
                      supplier.leadTimeDays == 0
                          ? '—'
                          : '${number(supplier.leadTimeDays)} days',
                    ),
                    ('Payment terms', supplier.paymentTerms),
                  ],
                  onTap: controller.itemCountForSupplier(supplier.id) == 0
                      ? null
                      : () => context.go('/items?supplier=${supplier.id}'),
                  onEdit: () => _edit(context, controller, supplier),
                  onArchive: () =>
                      _confirmArchive(context, controller, supplier),
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
    Supplier? existing,
  ) async {
    final result = await showDialog<Supplier>(
      context: context,
      builder: (_) => _SupplierDialog(existing: existing),
    );
    if (result == null) return;

    if (existing == null) {
      await controller.createSupplier(result);
    } else {
      await controller.updateSupplier(existing.id, result);
    }
  }

  /// Archives rather than deletes, and says so.
  ///
  /// Purchase orders reference suppliers, and those references have to stay
  /// resolvable — an order whose supplier had been erased could no longer say
  /// who it was placed with. Archiving takes them out of the pickers and
  /// leaves the record intact.
  Future<void> _confirmArchive(
    BuildContext context,
    InventoryController controller,
    Supplier supplier,
  ) async {
    final linked = controller.itemCountForSupplier(supplier.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive supplier'),
        content: Text(
          linked == 0
              ? 'Take ${supplier.name} out of the pickers? Orders already '
                    'placed with them keep the record.'
              : 'Take ${supplier.name} out of the pickers? The '
                    '${linked == 1 ? '1 item' : '$linked items'} supplied by '
                    'them keep the name on record but lose the link, and '
                    'orders already placed keep the record.',
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
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.archiveSupplier(supplier.id);
  }
}

class _SupplierDialog extends StatefulWidget {
  const _SupplierDialog({this.existing});

  final Supplier? existing;

  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _contact = TextEditingController(
    text: widget.existing?.contactName ?? '',
  );
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late final _address = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late final _leadTime = TextEditingController(
    text: (widget.existing?.leadTimeDays ?? 0) == 0
        ? ''
        : '${widget.existing!.leadTimeDays}',
  );
  late final _terms = TextEditingController(
    text: widget.existing?.paymentTerms ?? '',
  );

  @override
  void dispose() {
    for (final c in [
      _name,
      _contact,
      _phone,
      _email,
      _address,
      _leadTime,
      _terms,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final now = DateTime.now();
    Navigator.of(context).pop(
      Supplier(
        id: widget.existing?.id ?? '',
        name: _name.text.trim(),
        contactName: _contact.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        address: _address.text.trim(),
        leadTimeDays: int.tryParse(_leadTime.text.trim()) ?? 0,
        paymentTerms: _terms.text.trim(),
        notes: widget.existing?.notes ?? '',
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;

    return AlertDialog(
      title: Text(isNew ? 'Add Supplier' : 'Edit Supplier'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Business name',
                    hintText: 'e.g. Nexa Components',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Give the supplier a name.'
                      : null,
                ),
                const SizedBox(height: Insets.md),
                TextFormField(
                  controller: _contact,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Contact person',
                  ),
                ),
                const SizedBox(height: Insets.md),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: TextFormField(
                        controller: _leadTime,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Lead time (days)',
                          hintText: '0',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.md),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: Insets.md),
                TextFormField(
                  controller: _terms,
                  decoration: const InputDecoration(
                    labelText: 'Payment terms',
                    hintText: 'e.g. 30 days',
                  ),
                ),
                const SizedBox(height: Insets.md),
                TextFormField(
                  controller: _address,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(isNew ? 'Add Supplier' : 'Save'),
        ),
      ],
    );
  }
}
