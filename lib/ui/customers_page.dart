import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/palette.dart';
import '../models/party.dart';
import '../state/inventory_controller.dart';
import 'widgets/contact_card.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';

class CustomersPage extends StatelessWidget {
  const CustomersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final customers = controller.customers;
    final p = context.palette;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Customers',
              subtitle: 'Who you sell to, and at which price',
              actions: [
                FilledButton.icon(
                  onPressed: () => _edit(context, controller, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Customer'),
                ),
              ],
            ),
            if (customers.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.groups_outlined,
                  title: 'No customers yet',
                  body:
                      'Recording customers lets a sale pick the right price '
                      'tier automatically.',
                  action: FilledButton.icon(
                    onPressed: () => _edit(context, controller, null),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Customer'),
                  ),
                ),
              )
            else
              for (final customer in customers) ...[
                ContactCard(
                  name: customer.name,
                  badge: TierBadge(label: customer.priceTier.label),
                  subtitle: [
                    if (customer.contactName.isNotEmpty) customer.contactName,
                    if (customer.phone.isNotEmpty) customer.phone,
                    if (customer.email.isNotEmpty) customer.email,
                  ].join(' · '),
                  facts: [
                    ('Price tier', customer.priceTier.label),
                    ('Address', customer.address),
                  ],
                  onEdit: () => _edit(context, controller, customer),
                  onArchive: () =>
                      _confirmArchive(context, controller, customer),
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
    Customer? existing,
  ) async {
    final result = await showDialog<Customer>(
      context: context,
      builder: (_) => _CustomerDialog(existing: existing),
    );
    if (result == null) return;

    if (existing == null) {
      await controller.createCustomer(result);
    } else {
      await controller.updateCustomer(existing.id, result);
    }
  }

  /// Archives rather than deletes, and says so.
  ///
  /// Invoices and receipts reference customers, and those references have to
  /// stay resolvable — a document whose customer had been erased could no
  /// longer say who it was for.
  Future<void> _confirmArchive(
    BuildContext context,
    InventoryController controller,
    Customer customer,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive customer'),
        content: Text('Remove ${customer.name}?'),
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
    if (confirmed == true) await controller.archiveCustomer(customer.id);
  }
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.existing});

  final Customer? existing;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
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
  late PriceTier _tier = widget.existing?.priceTier ?? PriceTier.retailer;

  @override
  void dispose() {
    for (final c in [_name, _contact, _phone, _email, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final now = DateTime.now();
    Navigator.of(context).pop(
      Customer(
        id: widget.existing?.id ?? '',
        name: _name.text.trim(),
        contactName: _contact.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        address: _address.text.trim(),
        priceTier: _tier,
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
      title: Text(isNew ? 'Add Customer' : 'Edit Customer'),
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
                    hintText: 'e.g. Kola Stores',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Give the customer a name.'
                      : null,
                ),
                const SizedBox(height: Insets.md),
                DropdownButtonFormField<PriceTier>(
                  initialValue: _tier,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Price tier',
                    helperText: 'Which sales price a sale to them defaults to',
                  ),
                  items: [
                    for (final tier in PriceTier.values)
                      DropdownMenuItem(value: tier, child: Text(tier.label)),
                  ],
                  onChanged: (v) => setState(() => _tier = v ?? _tier),
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
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                    ),
                  ],
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
          child: Text(isNew ? 'Add Customer' : 'Save'),
        ),
      ],
    );
  }
}
