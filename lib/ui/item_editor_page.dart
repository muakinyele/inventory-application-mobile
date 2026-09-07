import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/photo_service.dart';
import '../models/item.dart';
import '../models/party.dart';
import '../state/inventory_controller.dart';
import 'scanner_page.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';

class ItemEditorPage extends StatefulWidget {
  const ItemEditorPage({super.key, this.itemId, this.initialBarcode});

  /// Null for a new item.
  final String? itemId;

  /// Pre-fills the barcode when the editor is reached from a failed scan.
  final String? initialBarcode;

  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _category;
  late final TextEditingController _location;
  late final TextEditingController _quantity;
  late final TextEditingController _reorderLevel;
  late final TextEditingController _unit;
  late final TextEditingController _unitCost;
  late final TextEditingController _retailerPrice;
  late final TextEditingController _distributorPrice;
  late final TextEditingController _supplier;
  late final TextEditingController _notes;

  Item? _existing;
  String? _photo;
  String? _supplierId;
  late final TextEditingController _unitsPerPack;
  bool _initialised = false;

  /// Zero shows as an empty box so there is nothing to clear before typing.
  static String _numText(num value) => value == 0 ? '' : '$value';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;

    final controller = context.read<InventoryController>();
    final existing = widget.itemId == null
        ? null
        : controller.byId(widget.itemId!);
    _existing = existing;
    _photo = existing?.photo;

    _name = TextEditingController(text: existing?.name ?? '');
    _sku = TextEditingController(text: existing?.sku ?? '');
    _barcode = TextEditingController(
      text: existing?.barcode ?? widget.initialBarcode ?? '',
    );
    _category = TextEditingController(text: existing?.category ?? '');
    _location = TextEditingController(text: existing?.location ?? '');
    _quantity = TextEditingController(
      text: existing == null ? '' : _numText(existing.quantity),
    );
    _reorderLevel = TextEditingController(
      text: existing == null ? '' : _numText(existing.reorderLevel),
    );
    _unit = TextEditingController(
      text: existing?.unit ?? controller.settings.units.firstOrNull ?? 'pcs',
    );
    _unitCost = TextEditingController(
      text: existing == null ? '' : _numText(existing.unitCost),
    );
    _retailerPrice = TextEditingController(
      text: existing == null ? '' : _numText(existing.retailerPrice),
    );
    _distributorPrice = TextEditingController(
      text: existing == null ? '' : _numText(existing.distributorPrice),
    );
    _supplier = TextEditingController(text: existing?.supplier ?? '');
    _supplierId = existing?.supplierId;
    _unitsPerPack = TextEditingController(
      text: (existing?.unitsPerPack ?? 1) == 1
          ? ''
          : '${existing!.unitsPerPack}',
    );
    _notes = TextEditingController(text: existing?.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _sku,
      _barcode,
      _category,
      _location,
      _quantity,
      _reorderLevel,
      _unit,
      _unitCost,
      _retailerPrice,
      _distributorPrice,
      _supplier,
      _unitsPerPack,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int _int(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
  double _double(TextEditingController c) => parseAmount(c.text) ?? 0;

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final controller = context.read<InventoryController>();
    final now = DateTime.now();
    final unit = _unit.text.trim();

    final draft = Item(
      id: _existing?.id ?? '',
      name: _name.text.trim(),
      sku: _sku.text.trim(),
      barcode: _barcode.text.trim(),
      category: _category.text.trim(),
      location: _location.text.trim(),
      quantity: _int(_quantity),
      reorderLevel: _int(_reorderLevel),
      unit: unit.isEmpty ? 'pcs' : unit,
      unitCost: _double(_unitCost),
      retailerPrice: _double(_retailerPrice),
      distributorPrice: _double(_distributorPrice),
      supplier: _supplier.text.trim(),
      supplierId: _supplierId,
      unitsPerPack: (int.tryParse(_unitsPerPack.text.trim()) ?? 1).clamp(
        1,
        100000,
      ),
      notes: _notes.text.trim(),
      photo: _photo,
      createdAt: _existing?.createdAt ?? now,
      updatedAt: now,
    );

    final existing = _existing;
    if (existing == null) {
      final created = controller.createItem(draft);
      _notify('${created.name} added');
      context.go('/items/${created.id}');
    } else {
      controller.updateItem(existing.id, draft);
      _notify('${draft.name} updated');
      context.go('/items/${existing.id}');
    }
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickPhoto() async {
    // Desktop and web have no camera roll worth offering a choice over.
    final canUseCamera =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    var source = ImageSource.gallery;
    if (canUseCamera) {
      final chosen = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from library'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                onTap: () =>
                    Navigator.of(sheetContext).pop(ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (chosen == null) return;
      source = chosen;
    }

    try {
      final encoded = await const PhotoService().pick(source);
      if (encoded != null && mounted) setState(() => _photo = encoded);
    } catch (_) {
      if (mounted) _notify('That photo could not be used.');
    }
  }

  Future<void> _scanBarcode() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code != null && mounted) setState(() => _barcode.text = code);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final symbol = currencySymbol(controller.settings.currency);

    if (widget.itemId != null && _existing == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: EmptyState(
          icon: Icons.help_outline,
          title: 'Item not found',
          body: 'It may have been deleted while this screen was open.',
          action: FilledButton(
            onPressed: () => context.go('/items'),
            child: const Text('Back to items'),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.palette.plane,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: PageBody(
            children: [
              PageHeader(
                title: _existing == null ? 'New Item' : 'Edit Item',
                subtitle: _existing == null
                    ? 'Add a product to your catalogue'
                    : _existing!.name,
                showBack: true,
              ),
              _photoPicker(),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Item name',
                  hintText: 'e.g. USB-C Cable 2m',
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Give the item a name.'
                    : null,
              ),
              const SizedBox(height: 12),
              _pair(
                TextFormField(
                  controller: _sku,
                  decoration: const InputDecoration(
                    labelText: 'SKU',
                    hintText: 'CBL-USBC-2M',
                  ),
                ),
                TextFormField(
                  controller: _barcode,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Barcode',
                    hintText: 'Scan or type',
                    suffixIcon: IconButton(
                      tooltip: 'Scan barcode',
                      onPressed: _scanBarcode,
                      icon: const Icon(Icons.qr_code_scanner, size: 20),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _pair(
                _autocomplete(
                  controller: _category,
                  label: 'Category',
                  hint: 'Electronics',
                  options: controller.settings.categories,
                ),
                _autocomplete(
                  controller: _location,
                  label: 'Location',
                  hint: 'Main Warehouse',
                  options: controller.settings.locations,
                ),
              ),
              const SizedBox(height: 12),
              _pair(
                TextFormField(
                  controller: _quantity,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Quantity on hand',
                    hintText: '0',
                  ),
                ),
                _autocomplete(
                  controller: _unit,
                  label: 'Unit',
                  hint: 'pcs',
                  options: controller.settings.units,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reorderLevel,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Reorder level',
                  hintText: '0',
                  helperMaxLines: 2,
                  helperText:
                      'The app flags the item once stock drops to this number. '
                      'Leave blank to never flag it.',
                ),
              ),
              const SizedBox(height: 12),
              _pair(
                TextFormField(
                  controller: _unitCost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Unit cost ($symbol)',
                    hintText: '0.00',
                  ),
                  validator: _money,
                ),
                TextFormField(
                  controller: _retailerPrice,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Retailer sales price ($symbol)',
                    hintText: '0.00',
                  ),
                  validator: _money,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _distributorPrice,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Distributor sales price ($symbol)',
                  hintText: '0.00',
                ),
                validator: _money,
              ),
              const SizedBox(height: 12),
              _pair(
                _supplierField(controller.suppliers),
                TextFormField(
                  controller: _unitsPerPack,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Units per pack',
                    hintText: '1',
                    helperMaxLines: 2,
                    helperText: 'How many units come in one purchase pack.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Anything worth remembering about this item',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => context.pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: Text(
                        _existing == null ? 'Add item' : 'Save changes',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A dropdown once suppliers exist, so items link to a record; free text
  /// until then, so the field is never a dead end on a fresh install.
  Widget _supplierField(List<Supplier> suppliers) {
    if (suppliers.isEmpty) {
      return TextFormField(
        controller: _supplier,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Supplier',
          hintText: 'Who you buy it from',
          helperMaxLines: 2,
          helperText: 'Add suppliers to pick from a list instead.',
        ),
      );
    }

    final known = suppliers.any((s) => s.id == _supplierId);
    return DropdownButtonFormField<String?>(
      initialValue: known ? _supplierId : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Supplier',
        helperMaxLines: 2,
        helperText: _supplierId == null && _supplier.text.trim().isNotEmpty
            ? 'Currently "${_supplier.text.trim()}", not linked to a record.'
            : null,
      ),
      items: [
        const DropdownMenuItem(child: Text('None')),
        for (final supplier in suppliers)
          DropdownMenuItem(value: supplier.id, child: Text(supplier.name)),
      ],
      onChanged: (value) => setState(() {
        _supplierId = value;
        // Keep the free-text name in step so exports stay readable.
        _supplier.text =
            suppliers
                .where((s) => s.id == value)
                .map((s) => s.name)
                .firstOrNull ??
            '';
      }),
    );
  }

  String? _money(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return null;
    final parsed = parseAmount(raw);
    if (parsed == null) return 'Enter an amount, or leave it blank.';
    if (parsed < 0) return 'Cannot be negative.';
    return null;
  }

  /// Side-by-side on anything wider than a narrow phone, stacked below that.
  Widget _pair(Widget left, Widget right) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 360) {
          return Column(children: [left, const SizedBox(height: 12), right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ],
        );
      },
    );
  }

  Widget _autocomplete({
    required TextEditingController controller,
    required String label,
    required String hint,
    required List<String> options,
  }) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return options;
        return options.where((o) => o.toLowerCase().contains(query));
      },
      onSelected: (value) => controller.text = value,
      fieldViewBuilder: (context, fieldController, focusNode, onSubmitted) {
        // Keep the outer controller in step; it is what _save() reads.
        fieldController.addListener(
          () => controller.text = fieldController.text,
        );
        return TextFormField(
          controller: fieldController,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onFieldSubmitted: (_) => onSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, opts) {
        final p = context.palette;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            color: p.surface,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                children: [
                  for (final option in opts)
                    InkWell(
                      onTap: () => onSelected(option),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(option),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _photoPicker() {
    final p = context.palette;
    final photo = _photo;
    Uint8List? bytes;
    if (photo != null) {
      try {
        bytes = base64Decode(photo);
      } on FormatException {
        bytes = null;
      }
    }

    return Row(
      children: [
        InkWell(
          onTap: _pickPhoto,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: 84,
            height: 84,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.lineStrong),
            ),
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                : Center(
                    child: _name.text.trim().isEmpty
                        ? Icon(
                            Icons.photo_camera_outlined,
                            size: 26,
                            color: p.inkMuted,
                          )
                        : Text(
                            initials(_name.text),
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: p.inkMuted,
                            ),
                          ),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              onPressed: _pickPhoto,
              child: Text(photo == null ? 'Add photo' : 'Replace photo'),
            ),
            if (photo != null)
              TextButton(
                onPressed: () => setState(() => _photo = null),
                child: const Text('Remove'),
              ),
          ],
        ),
      ],
    );
  }
}
