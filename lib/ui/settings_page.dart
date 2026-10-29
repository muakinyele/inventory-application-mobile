import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/csv_codec.dart';
import '../data/export_service.dart';
import '../data/receipt_document.dart';
import '../data/snapshot.dart';
import '../models/app_settings.dart';
import '../state/auth_controller.dart';
import '../state/inventory_controller.dart';
import 'cancelled_sales_check_page.dart';
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

  /// Which long-running job is on, so its row can show a spinner and refuse a
  /// second tap. Null when nothing is running.
  String? _busyRow;

  bool _isBusy(String row) => _busyRow == row;

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
    // Taken before the fetch: it is where the row was when it was tapped, and
    // reading a BuildContext after an await is how that becomes a crash on a
    // screen that has since been left.
    final origin = shareOriginOf(buttonContext);

    // Fetched here rather than at sign-in. Settings is not a document screen
    // — somebody opening it to change the tax rate should not wait on the
    // receipt book — but the export plainly needs it, and without this the
    // button would report "nothing to export" for a workspace full of them.
    setState(() => _busyRow = 'receipts-export');
    await controller.ensureDocuments(const {DocumentSet.receipts});
    if (!mounted) return;
    setState(() => _busyRow = null);

    if (controller.receipts.isEmpty) {
      _notify('No receipts to export yet.', tone: MessageTone.warning);
      return;
    }
    await const ExportService().shareText(
      filename: 'receipts.csv',
      contents: receiptsToCsv(controller.receipts, controller.settings),
      mimeType: 'text/csv',
      originRect: origin,
    );
    if (mounted) {
      _notify('${number(controller.receipts.length)} receipts exported');
    }
  }

  /// Downloads the whole workspace as JSON.
  ///
  /// THIS USED TO BE FOUR OF EIGHTEEN TABLES. It was assembled here from what
  /// the controller had in memory — items, movements, receipts and settings —
  /// which left out suppliers, customers, purchase orders, sales orders,
  /// invoices, transfers and, most consequentially, the per-bin stock levels.
  /// A workspace restored from one of those files would have come back with
  /// no trading partners, no documents, and every count in the wrong place.
  /// It was also capped at the one page of items the app had loaded.
  ///
  /// The server takes it now, straight from the tables.
  Future<void> _exportBackup(BuildContext buttonContext) async {
    final controller = context.read<InventoryController>();
    // Taken before the await: it is where the row was when it was tapped, and
    // reading a BuildContext after an await is how that becomes a crash on a
    // screen that has since been left.
    final origin = shareOriginOf(buttonContext);

    setState(() => _busyRow = 'backup');
    final payload = await controller.exportBackup();
    if (!mounted) return;
    setState(() => _busyRow = null);

    if (payload == null) {
      await _notify(
        'The backup could not be taken, so no file was saved. '
        'Check your connection and try again.',
        tone: MessageTone.failure,
      );
      return;
    }

    final tables = payload['tables'];
    final rows = tables is Map
        ? tables.values.fold<int>(
            0,
            (sum, t) => sum + (t is List ? t.length : 0),
          )
        : 0;

    final stamp = DateTime.now().toIso8601String().split('T').first;
    await const ExportService().shareText(
      filename: 'stockpile-backup-$stamp.json',
      contents: const JsonEncoder.withIndent('  ').convert(payload),
      mimeType: 'application/json',
      originRect: origin,
    );
    if (mounted) _notify('Backup saved — ${number(rows)} rows');
  }

  /// Replaces the workspace from a backup file.
  ///
  /// Guarded twice on purpose. This is the most destructive thing in the app:
  /// it does not merge, it replaces, and what it replaces is everything.
  Future<void> _restoreBackup() async {
    final controller = context.read<InventoryController>();

    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;

    Map<String, dynamic> payload;
    try {
      // Bytes rather than a path: on web there is no path to read.
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      payload = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      if (mounted) {
        await _notify(
          'That file could not be read as a backup.',
          tone: MessageTone.failure,
        );
      }
      return;
    }

    // Described before it is agreed to, so the confirmation says what will
    // actually happen rather than "are you sure?".
    //
    // TWO SHAPES. Backups this app wrote before the server took the job over
    // are `{version, items, movements, receipts, settings}` with no `tables`
    // key at all — and reading only the new shape told people holding one that
    // their backup was empty. It is not; it is older. The server converts it;
    // this only has to count it.
    final tables = payload['tables'];
    final source = tables is Map ? tables : payload;
    final counts = <String, int>{
      for (final entry in source.entries)
        if (entry.value is List && (entry.value as List).isNotEmpty)
          entry.key.toString(): (entry.value as List).length,
    };

    // The old shape kept the workspace's settings as an object rather than a
    // row count, so it would otherwise not appear in the summary at all.
    if (tables is! Map && payload['settings'] is Map) {
      counts['preferences'] = (payload['settings'] as Map).length;
    }

    if (counts.isEmpty) {
      if (mounted) {
        await _notify(
          'That backup has nothing in it, so there is nothing to restore.',
          tone: MessageTone.failure,
        );
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Everything in this workspace will be replaced by the '
                'contents of this file. Items, stock levels, documents, '
                'partners and settings that are not in the backup will be '
                'gone.',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 14),
              Text(
                'The backup holds:',
                style: Theme.of(dialogContext).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              for (final entry in counts.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${_tableLabel(entry.key)}: ${number(entry.value)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              if (payload['takenAt'] is String) ...[
                const SizedBox(height: 10),
                Text(
                  'Taken ${(payload['takenAt'] as String).split('T').first}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Replace everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyRow = 'restore');
    final result = await controller.restoreBackup(payload);
    if (!mounted) return;
    setState(() => _busyRow = null);

    if (!result.ok) {
      await _notify(
        'The restore did not happen, and nothing was changed. '
        '${_messageFor(result.error)}',
        tone: MessageTone.failure,
      );
      return;
    }
    await _notify('Restored ${number(result.rows)} rows.');
  }

  /// Brings receipts in from a sheet.
  ///
  /// The counterpart to "Export receipts (CSV)", which has existed on its own
  /// since the beginning — a one-way door out of the app.
  Future<void> _importReceipts() async {
    final controller = context.read<InventoryController>();

    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (file == null) return;

    String text;
    try {
      text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } catch (_) {
      if (mounted) {
        await _notify(
          'That file could not be read.',
          tone: MessageTone.failure,
        );
      }
      return;
    }

    final parsed = csvToReceipts(text);
    if (parsed.receipts.isEmpty) {
      if (mounted) {
        await _notify(
          parsed.errors.firstOrNull ?? 'No receipts could be read from that.',
          tone: MessageTone.failure,
        );
      }
      return;
    }

    // Said plainly before it happens, because this is the part people get
    // wrong: imported receipts are history, and re-booking their stock would
    // leave every count short by the whole import.
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Import ${number(parsed.receipts.length)} receipts?'),
        content: SizedBox(
          width: 420,
          child: Text(
            'They come in as history: stock is not moved, because these sales '
            'already took their goods wherever they were first recorded. '
            'Each gets a new reference from this workspace.'
            '${parsed.errors.isEmpty ? '' : '\n\n${number(parsed.errors.length)} rows had problems and will be left out.'}',
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyRow = 'receipts-import');
    final result = await controller.importReceipts(parsed.receipts);
    if (!mounted) return;
    setState(() => _busyRow = null);

    if (result.imported == 0) {
      await _notify(
        'None of those receipts could be saved, so nothing was added.',
        tone: MessageTone.failure,
      );
      return;
    }

    await _notify(
      result.failed.isEmpty
          ? 'Imported ${number(result.imported)} receipts'
          : 'Imported ${number(result.imported)} receipts. '
                '${number(result.failed.length)} could not be saved: '
                '${result.failed.take(3).join(', ')}'
                '${result.failed.length > 3 ? '…' : ''}',
      tone: result.failed.isEmpty ? MessageTone.success : MessageTone.warning,
    );
  }

  /// A table name as somebody reading a dialog would say it.
  String _tableLabel(String table) => switch (table) {
    'items' => 'Items',
    'movements' => 'Stock movements',
    'stockLevels' => 'Stock by location',
    'suppliers' => 'Suppliers',
    'customers' => 'Customers',
    'categories' => 'Categories',
    'lookups' => 'Picker lists',
    'preferences' => 'Settings',
    'purchaseOrders' => 'Purchase orders',
    'purchaseOrderLines' => 'Purchase order lines',
    'salesOrders' => 'Sales orders',
    'salesOrderLines' => 'Sales order lines',
    'transfers' => 'Transfers',
    'transferLines' => 'Transfer lines',
    'invoices' => 'Invoices',
    'invoiceLines' => 'Invoice lines',
    'receipts' => 'Receipts',
    'receiptLines' => 'Receipt lines',
    _ => table,
  };

  /// The server's own words where it gave any, since they say which file was
  /// wrong and why.
  String _messageFor(Object? error) {
    final text = error?.toString() ?? '';
    final match = RegExp(r'[A-Z][^]*?[.!]').firstMatch(text);
    return match?.group(0) ?? 'Check your connection and try again.';
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
                      busy: _isBusy('receipts-export'),
                      onTap: () => _exportReceipts(rowContext),
                    ),
                  ),
                  Divider(color: p.line, height: 1),
                  _MenuRow(
                    icon: Icons.upload_outlined,
                    label: 'Import receipts (CSV)',
                    busy: _isBusy('receipts-import'),
                    onTap: _importReceipts,
                  ),
                  Divider(color: p.line, height: 1),
                  Builder(
                    builder: (rowContext) => _MenuRow(
                      icon: Icons.layers_outlined,
                      label: 'Export full backup (JSON)',
                      note: 'everything',
                      busy: _isBusy('backup'),
                      onTap: () => _exportBackup(rowContext),
                    ),
                  ),
                  Divider(color: p.line, height: 1),
                  _MenuRow(
                    icon: Icons.settings_backup_restore,
                    label: 'Restore from backup (JSON)',
                    onTap: _restoreBackup,
                    busy: _isBusy('restore'),
                    danger: true,
                  ),
                  if (context.watch<AuthController?>()?.can(
                        'settings.manage',
                      ) ??
                      false) ...[
                    Divider(color: p.line, height: 1),
                    _MenuRow(
                      icon: Icons.fact_check_outlined,
                      label: 'Check cancelled sales',
                      note: 'stock not returned',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CancelledSalesCheckPage(),
                        ),
                      ),
                    ),
                  ],
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
                // WAS THE OPPOSITE OF TRUE. It said the workspace lived on
                // this device with no account and no server, which described
                // the app two rewrites ago. Everything is on the server and
                // shared by everyone signed in — and somebody reading the old
                // words would have thought clearing their browser was safe.
                'Your inventory is stored on the server and shared with '
                'everyone signed in to this workspace, so a change made here '
                'shows up on their screens too. A signed-in connection is '
                'needed to use it. The JSON backup is a full copy you can '
                'keep, and restore from.',
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
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final String? note;
  final IconData? trailing;
  final bool danger;

  /// Work in progress on THIS row. A spinner here rather than a dialog over
  /// the page: a modal that says "working…" has to be dismissed before the
  /// outcome can be shown, which is how a backup that was busy reading a file
  /// looked like an app that had stopped.
  final bool busy;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tint = danger ? p.critical : p.accent;

    return InkWell(
      // Not tappable twice: a second restore starting while the first is still
      // running would race two whole-workspace replacements.
      onTap: busy ? null : onTap,
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
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (note != null)
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
