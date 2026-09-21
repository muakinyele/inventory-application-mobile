import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/csv_codec.dart';
import '../data/export_service.dart';
import '../data/receipt_document.dart';
import '../models/app_settings.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/section_card.dart';
import 'widgets/company_logo_field.dart';
import 'widgets/page_header.dart';

const _currencies = [
  'NGN',
  'USD',
  'EUR',
  'GBP',
  'CAD',
  'AUD',
  'ZAR',
  'INR',
  'KES',
  'GHS',
];

enum _ListKind { categories, locations, units }

const _listTitles = {
  _ListKind.categories: 'Categories',
  _ListKind.locations: 'Locations',
  _ListKind.units: 'Units',
};

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _companyName;
  late final TextEditingController _companyAddress;
  late final TextEditingController _companyPhone;
  late final TextEditingController _companyEmail;
  late final TextEditingController _taxLabel;
  late final TextEditingController _taxRate;
  late final TextEditingController _receiptFooter;

  @override
  void initState() {
    super.initState();
    final settings = context.read<InventoryController>().settings;
    _companyName = TextEditingController(text: settings.companyName);
    _companyAddress = TextEditingController(text: settings.companyAddress);
    _companyPhone = TextEditingController(text: settings.companyPhone);
    _companyEmail = TextEditingController(text: settings.companyEmail);
    _taxLabel = TextEditingController(text: settings.taxLabel);
    // Held as a percentage in the field and a fraction in the model, which is
    // the way round each is easiest to read.
    _taxRate = TextEditingController(
      text: settings.taxRate == 0 ? '' : _trimZeroes(settings.taxRate * 100),
    );
    _receiptFooter = TextEditingController(text: settings.receiptFooter);
  }

  @override
  void dispose() {
    _companyName.dispose();
    _companyAddress.dispose();
    _companyPhone.dispose();
    _companyEmail.dispose();
    _taxLabel.dispose();
    _taxRate.dispose();
    _receiptFooter.dispose();
    super.dispose();
  }

  static String _trimZeroes(double value) {
    final text = value.toStringAsFixed(3);
    return text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  List<String> _listFor(AppSettings settings, _ListKind kind) => switch (kind) {
    _ListKind.categories => settings.categories,
    _ListKind.locations => settings.locations,
    _ListKind.units => settings.units,
  };

  AppSettings _withList(
    AppSettings settings,
    _ListKind kind,
    List<String> values,
  ) => switch (kind) {
    _ListKind.categories => settings.copyWith(categories: values),
    _ListKind.locations => settings.copyWith(locations: values),
    _ListKind.units => settings.copyWith(units: values),
  };

  Future<void> _exportItems(BuildContext buttonContext) async {
    final controller = context.read<InventoryController>();
    if (controller.items.isEmpty) {
      _notify('Nothing to export yet.', tone: MessageTone.warning);
      return;
    }
    await const ExportService().shareText(
      filename: 'inventory-items.csv',
      contents: itemsToCsv(controller.items),
      mimeType: 'text/csv',
      originRect: shareOriginOf(buttonContext),
    );
    if (mounted) _notify('${number(controller.items.length)} items exported');
  }

  Future<void> _exportReceipts(BuildContext buttonContext) async {
    final controller = context.read<InventoryController>();
    if (controller.receipts.isEmpty) {
      _notify('No receipts to export yet.', tone: MessageTone.warning);
      return;
    }
    await const ExportService().shareText(
      filename: 'receipts.csv',
      contents: receiptsToCsv(controller.receipts, controller.settings),
      mimeType: 'text/csv',
      originRect: shareOriginOf(buttonContext),
    );
    if (mounted) {
      _notify('${number(controller.receipts.length)} receipts exported');
    }
  }

  Future<void> _exportBackup(BuildContext buttonContext) async {
    final controller = context.read<InventoryController>();
    final payload = {
      'version': 1,
      'items': controller.items.map((i) => i.toJson()).toList(),
      'movements': controller.movements.map((m) => m.toJson()).toList(),
      'receipts': controller.receipts.map((r) => r.toJson()).toList(),
      'settings': controller.settings.toJson(),
    };
    await const ExportService().shareText(
      filename: 'inventory-backup.json',
      contents: const JsonEncoder.withIndent('  ').convert(payload),
      mimeType: 'application/json',
      originRect: shareOriginOf(buttonContext),
    );
    if (mounted) _notify('Backup exported');
  }

  Future<void> _importCsv() async {
    final controller = context.read<InventoryController>();
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (file == null) return;

    String text;
    try {
      // Bytes rather than a path: on web there is no file path to read.
      text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } catch (_) {
      if (mounted) {
        _notify('That file could not be read.', tone: MessageTone.failure);
      }
      return;
    }

    final result = csvToItems(text);
    if (result.items.isEmpty) {
      if (mounted) {
        _notify(
          result.errors.firstOrNull ?? 'No rows could be imported.',
          tone: MessageTone.failure,
        );
      }
      return;
    }

    final count = controller.importDrafts(result.items);
    if (!mounted) return;
    _notify(
      result.errors.isEmpty
          ? 'Imported ${number(count)} items'
          : 'Imported ${number(count)} items, skipped ${result.errors.length}',
      tone: result.errors.isEmpty ? MessageTone.success : MessageTone.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final settings = controller.settings;
    final p = context.palette;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Settings',
              subtitle: '${number(controller.items.length)} items tracked',
            ),
            SectionCard(
              title: 'Workspace',
              child: Column(
                children: [
                  TextField(
                    controller: _companyName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Workspace name',
                    ),
                    onChanged: (value) => controller.updateSettings(
                      settings.copyWith(
                        companyName: value.trim().isEmpty
                            ? 'My Inventory'
                            : value,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _currencies.contains(settings.currency)
                        ? settings.currency
                        : _currencies.first,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: [
                      for (final code in _currencies)
                        DropdownMenuItem(value: code, child: Text(code)),
                    ],
                    onChanged: (value) => value == null
                        ? null
                        : controller.updateSettings(
                            settings.copyWith(currency: value),
                          ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ThemeMode>(
                    initialValue: settings.themeMode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Appearance'),
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('Match device'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Light'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Dark'),
                      ),
                    ],
                    onChanged: (value) => value == null
                        ? null
                        : controller.updateSettings(
                            settings.copyWith(themeMode: value),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'Lists',
              child: Column(
                children: [
                  for (final kind in _ListKind.values) ...[
                    if (kind != _ListKind.values.first)
                      Divider(color: p.line, height: 1),
                    _MenuRow(
                      icon: switch (kind) {
                        _ListKind.categories => Icons.sell_outlined,
                        _ListKind.locations => Icons.place_outlined,
                        _ListKind.units => Icons.layers_outlined,
                      },
                      label: _listTitles[kind]!,
                      note: '${_listFor(settings, kind).length}',
                      trailing: Icons.chevron_right,
                      onTap: () => _openListEditor(kind),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              // Named for both, because these fields drive the invoice
              // letterhead exactly as much as the receipt's.
              title: 'Invoices & receipts',
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'What gets printed at the head and foot of an invoice '
                      'or receipt, and the tax new ones are raised at. Each '
                      'receipt keeps its own copy of the rate, so changing it '
                      'here never alters what a customer was already charged.',
                      style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                    ),
                  ),
                  const SizedBox(height: 18),
                  CompanyLogoField(
                    settings: settings,
                    onChanged: (encoded) => controller.updateSettings(
                      settings.copyWith(companyLogo: encoded),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Divider(height: 1, color: p.line),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _companyAddress,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Business address',
                    ),
                    onChanged: (value) => controller.updateSettings(
                      settings.copyWith(companyAddress: value),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _companyPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone'),
                          onChanged: (value) => controller.updateSettings(
                            settings.copyWith(companyPhone: value),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _companyEmail,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email'),
                          onChanged: (value) => controller.updateSettings(
                            settings.copyWith(companyEmail: value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _taxLabel,
                          decoration: const InputDecoration(
                            labelText: 'Tax name',
                            helperText: 'VAT, GST, Sales Tax',
                          ),
                          onChanged: (value) => controller.updateSettings(
                            settings.copyWith(
                              taxLabel: value.trim().isEmpty ? 'VAT' : value,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _taxRate,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Tax rate (%)',
                            helperText: 'Leave blank for none',
                          ),
                          onChanged: (value) {
                            final percent = parseAmount(value) ?? 0;
                            controller.updateSettings(
                              settings.copyWith(
                                taxRate: (percent / 100).clamp(0, 1).toDouble(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _receiptFooter,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Footer line',
                      helperText: 'The closing line on a printed receipt',
                    ),
                    onChanged: (value) => controller.updateSettings(
                      settings.copyWith(receiptFooter: value),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'Data',
              child: Column(
                children: [
                  Builder(
                    builder: (rowContext) => _MenuRow(
                      icon: Icons.download_outlined,
                      label: 'Export items (CSV)',
                      onTap: () => _exportItems(rowContext),
                    ),
                  ),
                  Divider(color: p.line, height: 1),
                  _MenuRow(
                    icon: Icons.upload_outlined,
                    label: 'Import items (CSV)',
                    onTap: _importCsv,
                  ),
                  Divider(color: p.line, height: 1),
                  Builder(
                    builder: (rowContext) => _MenuRow(
                      icon: Icons.receipt_long_outlined,
                      label: 'Export receipts (CSV)',
                      note: '${controller.receipts.length}',
                      onTap: () => _exportReceipts(rowContext),
                    ),
                  ),
                  Divider(color: p.line, height: 1),
                  Builder(
                    builder: (rowContext) => _MenuRow(
                      icon: Icons.layers_outlined,
                      label: 'Export full backup (JSON)',
                      onTap: () => _exportBackup(rowContext),
                    ),
                  ),
                  Divider(color: p.line, height: 1),
                  _MenuRow(
                    icon: Icons.refresh,
                    label: 'Load sample catalogue',
                    onTap: () {
                      controller.loadSampleData();
                      _companyName.text = controller.settings.companyName;
                      _notify('Sample catalogue loaded');
                    },
                  ),
                  Divider(color: p.line, height: 1),
                  _MenuRow(
                    icon: Icons.delete_outline,
                    label: 'Erase all data',
                    danger: true,
                    onTap: _confirmErase,
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'A CSV import needs a "name" column; sku, quantity, '
                      'unitCost and the rest are optional. Export a file first '
                      'to see the shape.',
                      style: TextStyle(fontSize: 12, color: p.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'About',
              child: Text(
                'Everything is stored on this device only — no account, no '
                'server, and it keeps working offline. Use the JSON backup to '
                'move your data to another device.',
                style: TextStyle(color: p.inkSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmErase() async {
    final controller = context.read<InventoryController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Erase all data'),
        content: const Text(
          'This deletes every item and all movement history on this device. '
          'Export a backup first if you might want it back.',
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
            child: const Text('Erase everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    controller.eraseAll();
    _companyName.text = controller.settings.companyName;
    if (mounted) _notify('All data erased');
  }

  Future<void> _openListEditor(_ListKind kind) async {
    final controller = context.read<InventoryController>();
    final entry = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final settings = controller.settings;
            final values = _listFor(settings, kind);
            final p = sheetContext.palette;

            // AWAITED, AND REPORTED. These went out unawaited into a save
            // that swallowed its own failures, so an entry that never reached
            // the server still cleared the field and sat in the list until the
            // next load took it away again. The categories list is edited
            // here as well as on its own page, and this is the half that said
            // nothing.
            Future<void> add() async {
              final value = entry.text.trim();
              if (value.isEmpty) return;
              // Case-insensitive, because the server keys a category on its
              // name and "Parts" beside "parts" is two rows that read as one.
              if (values.any((v) => v.toLowerCase() == value.toLowerCase())) {
                _notify(
                  'That entry already exists.',
                  tone: MessageTone.warning,
                );
                return;
              }
              final saved = await controller.updateSettings(
                _withList(settings, kind, [...values, value]),
              );
              if (!saved) {
                await _notify(
                  '"$value" could not be saved, so it was not added. '
                  'Check your connection and try again.',
                  tone: MessageTone.failure,
                );
                return;
              }
              setSheetState(() => entry.clear());
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _listTitles[kind]!,
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: entry,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                hintText: 'Add a new entry',
                              ),
                              onSubmitted: (_) => add(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 48,
                            child: FilledButton(
                              onPressed: add,
                              child: const Text('Add'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          for (final value in values)
                            InputChip(
                              label: Text(value),
                              onDeleted: () async {
                                final saved = await controller.updateSettings(
                                  _withList(
                                    settings,
                                    kind,
                                    values.where((v) => v != value).toList(),
                                  ),
                                );
                                if (!saved) {
                                  await _notify(
                                    '"$value" could not be removed, so it is '
                                    'still here. Check your connection and '
                                    'try again.',
                                    tone: MessageTone.failure,
                                  );
                                }
                                setSheetState(() {});
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Removing an entry only takes it out of the picker — '
                        'items already using it keep their value.',
                        style: TextStyle(fontSize: 12, color: p.inkMuted),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    entry.dispose();
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.note,
    this.trailing,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String? note;
  final IconData? trailing;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tint = danger ? p.critical : p.accent;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: danger ? p.critical : p.ink,
                ),
              ),
            ),
            if (note != null)
              Text(note!, style: TextStyle(fontSize: 12.5, color: p.inkMuted)),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Icon(trailing, size: 18, color: p.inkMuted),
            ],
          ],
        ),
      ),
    );
  }
}
