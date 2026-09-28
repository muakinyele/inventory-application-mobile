import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/csv_codec.dart';
import '../data/export_service.dart';
import '../models/app_settings.dart';
import '../models/item.dart';
import '../state/inventory_controller.dart';
import 'scanner_page.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/page_header.dart';
import 'widgets/pagination.dart';
import 'widgets/product_card.dart';

enum SortKey { name, quantity, value, updated }

const _sortLabels = {
  SortKey.name: 'Name (A–Z)',
  SortKey.quantity: 'Quantity (low first)',
  SortKey.value: 'Stock value (high first)',
  SortKey.updated: 'Recently updated',
};

/// `null` is the "All" pill; the rest map to a stock status.
typedef _StatusFilter = StockStatus?;

class ItemsPage extends StatefulWidget {
  const ItemsPage({
    super.key,
    this.initialStatus,
    this.initialCategory,
    this.initialSupplierId,
    this.openScanner = false,
  });

  /// Set from `?status=` so the dashboard can deep-link into a filtered list.
  final StockStatus? initialStatus;

  /// Set from `?category=` so the Categories page can drill in.
  final String? initialCategory;

  /// Set from `?supplier=` so the Suppliers page can drill in.
  final String? initialSupplierId;

  /// Set from `?scan=1` so the dashboard's Scan action lands here.
  final bool openScanner;

  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  final _search = TextEditingController();
  _StatusFilter _status;
  String? _category;
  String? _location;

  /// Where in the list the reader is. Reset to the first page whenever the
  /// filters change, because page 7 of the old result set means nothing in
  /// the new one.
  PageCursor _cursor = const PageCursor();
  String? _supplierId;
  SortKey _sort = SortKey.name;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _category = widget.initialCategory;
    _supplierId = widget.initialSupplierId;
    if (widget.openScanner) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  @override
  void didUpdateWidget(ItemsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStatus != oldWidget.initialStatus ||
        widget.initialCategory != oldWidget.initialCategory ||
        widget.initialSupplierId != oldWidget.initialSupplierId) {
      setState(() {
        _status = widget.initialStatus;
        _category = widget.initialCategory;
        _supplierId = widget.initialSupplierId;
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
    MessageAction? action,
  }) {
    return showAppMessage(context, message, tone: tone, action: action);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code == null || !mounted) return;

    final controller = context.read<InventoryController>();
    final match = controller.byCode(code);
    if (match != null) {
      context.go('/items/${match.id}');
    } else {
      // Awaited: routing away takes the dialog down with the page it sits on.
      await _notify(
        'No item matches that code — starting a new one.',
        tone: MessageTone.info,
      );
      if (!mounted) return;
      context.go('/items/new?barcode=${Uri.encodeComponent(code)}');
    }
  }

  /// Applies a filter change and returns to the first page.
  ///
  /// Every control goes through here. `clamped` would stop a stale page
  /// rendering empty, but landing on the last page of a narrower result is
  /// still not where somebody who just typed a search expects to be: they
  /// expect the best match, which is at the top.
  void _refine(VoidCallback change) {
    setState(() {
      change();
      _cursor = _cursor.withPage(0);
    });
  }

  List<Item> _visible(InventoryController controller) {
    final query = _search.text.trim().toLowerCase();

    final result = controller.items.where((item) {
      if (_status != null && item.status != _status) return false;
      if (_category != null && item.category != _category) return false;
      if (_location != null && item.location != _location) return false;
      if (_supplierId != null && item.supplierId != _supplierId) return false;
      if (query.isEmpty) return true;
      return item.name.toLowerCase().contains(query) ||
          item.sku.toLowerCase().contains(query) ||
          item.barcode.contains(query) ||
          item.supplier.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query);
    }).toList();

    result.sort(switch (_sort) {
      SortKey.name => (a, b) => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      SortKey.quantity => (a, b) => a.quantity.compareTo(b.quantity),
      SortKey.value => (a, b) => b.stockValue.compareTo(a.stockValue),
      SortKey.updated => (a, b) => b.updatedAt.compareTo(a.updatedAt),
    });
    return result;
  }

  Future<void> _export(BuildContext buttonContext) async {
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

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final settings = controller.settings;
    final visible = _visible(controller);
    // Corrected against the filtered count, so a search run from deep in the
    // list lands on a page that exists rather than on an empty one that reads
    // as "nothing found".
    final cursor = _cursor.clamped(visible.length);
    final page = cursor.slice(visible);
    final p = context.palette;

    final categories = <String>{
      for (final item in controller.items)
        if (item.category.isNotEmpty) item.category,
    }.toList()..sort();

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                _gutter(context),
                Insets.xl,
                _gutter(context),
                0,
              ),
              child: Column(
                children: [
                  PageHeader(
                    title: 'Items',
                    subtitle:
                        '${number(visible.length)} shown · ${number(visible.fold(0, (s, i) => s + i.quantity))} units · '
                        '${money(visible.fold(0.0, (s, i) => s + i.stockValue), settings.currency)}',
                    actions: [
                      Builder(
                        builder: (buttonContext) => OutlinedButton.icon(
                          onPressed: () => _export(buttonContext),
                          icon: const Icon(
                            Icons.file_download_outlined,
                            size: 18,
                          ),
                          label: const Text('Export'),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/settings'),
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('Import'),
                      ),
                      FilledButton.icon(
                        onPressed: () => context.go('/items/new'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add Item'),
                      ),
                    ],
                  ),
                  _SearchRow(
                    controller: _search,
                    onChanged: (_) => _refine(() {}),
                    onScan: _scan,
                    onFilters: () => _openFilterSheet(controller),
                    extraFilters:
                        (_category != null ? 1 : 0) +
                        (_location != null ? 1 : 0),
                  ),
                  const SizedBox(height: Insets.md),
                  FilterChips<_StatusFilter>(
                    selected: _status,
                    onSelected: (value) => _refine(() => _status = value),
                    options: const [
                      FilterOption(null, 'All'),
                      FilterOption(StockStatus.low, 'Low Stock'),
                      FilterOption(StockStatus.out, 'Out of Stock'),
                      FilterOption(StockStatus.ok, 'In Stock'),
                    ],
                  ),
                  if (categories.isNotEmpty) ...[
                    const SizedBox(height: Insets.sm),
                    FilterChips<String?>(
                      selected: _category,
                      onSelected: (value) => _refine(() => _category = value),
                      options: [
                        const FilterOption(null, 'All categories'),
                        for (final name in categories)
                          FilterOption(
                            name,
                            name,
                            dotColor: settings.colorFor(name),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: Insets.lg),
                ],
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? EmptyState(
                      icon: controller.items.isEmpty
                          ? Icons.inventory_2_outlined
                          : Icons.search_off,
                      title: controller.items.isEmpty
                          ? 'No items yet'
                          : 'Nothing matches',
                      body: controller.items.isEmpty
                          ? 'Add your first item to start tracking stock.'
                          : 'Try a different search term or clear the filters.',
                      action: controller.items.isEmpty
                          ? FilledButton.icon(
                              onPressed: () => context.go('/items/new'),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add Item'),
                            )
                          : OutlinedButton(
                              onPressed: () => _refine(() {
                                _search.clear();
                                _status = null;
                                _category = null;
                                _location = null;
                                _supplierId = null;
                              }),
                              child: const Text('Clear filters'),
                            ),
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: _Grid(
                            items: page,
                            settings: settings,
                            onAdjust: (item, delta) =>
                                _quickAdjust(controller, item, delta),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: _gutter(context),
                          ),
                          child: PaginationBar(
                            cursor: cursor,
                            total: visible.length,
                            unfilteredTotal: controller.items.length,
                            filtered: visible.length != controller.items.length,
                            onCursor: (next) => setState(() => _cursor = next),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  double _gutter(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= Breakpoints.sidebar
      ? Insets.pageWide
      : Insets.pageNarrow;

  void _quickAdjust(InventoryController controller, Item item, int delta) {
    controller.adjustStock(
      item.id,
      delta,
      note: delta > 0 ? 'Quick add' : 'Quick remove',
    );
    _notify(
      '${item.name}: ${signed(delta)} ${item.unit}',
      action: MessageAction(
        label: 'Undo',
        onPressed: () =>
            controller.adjustStock(item.id, -delta, note: 'Undo quick change'),
      ),
    );
  }

  Future<void> _openFilterSheet(InventoryController controller) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void update(VoidCallback change) {
            setSheetState(change);
            _refine(change);
          }

          return SafeArea(
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
                    'Filter & sort',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: Insets.lg),
                  DropdownButtonFormField<String?>(
                    initialValue: _location,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Location'),
                    items: [
                      const DropdownMenuItem(child: Text('All locations')),
                      for (final l in controller.settings.locations)
                        DropdownMenuItem(value: l, child: Text(l)),
                    ],
                    onChanged: (v) => update(() => _location = v),
                  ),
                  const SizedBox(height: Insets.md),
                  DropdownButtonFormField<SortKey>(
                    initialValue: _sort,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Sort by'),
                    items: [
                      for (final entry in _sortLabels.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (v) => update(() => _sort = v!),
                  ),
                  const SizedBox(height: Insets.xl),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => update(() {
                            _category = null;
                            _location = null;
                            _supplierId = null;
                            _status = null;
                            _sort = SortKey.name;
                          }),
                          child: const Text('Reset'),
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: const Text('Show items'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.onChanged,
    required this.onScan,
    required this.onFilters,
    required this.extraFilters,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onScan;
  final VoidCallback onFilters;
  final int extraFilters;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search by name or SKU...',
              prefixIcon: Icon(Icons.search, size: 20, color: p.inkMuted),
              suffixIcon: IconButton(
                tooltip: 'Scan barcode',
                onPressed: onScan,
                icon: const Icon(Icons.qr_code_scanner, size: 20),
              ),
            ),
          ),
        ),
        const SizedBox(width: Insets.sm),
        Tooltip(
          message: 'Filter & sort',
          child: OutlinedButton(
            onPressed: onFilters,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
              backgroundColor: extraFilters > 0 ? p.accentWash : p.surface,
              side: BorderSide(
                color: extraFilters > 0 ? p.accent : p.lineStrong,
              ),
            ),
            child: Badge(
              isLabelVisible: extraFilters > 0,
              label: Text('$extraFilters'),
              backgroundColor: p.accent,
              child: Icon(Icons.tune, size: 20, color: p.inkSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.items,
    required this.settings,
    required this.onAdjust,
  });

  final List<Item> items;
  final AppSettings settings;
  final void Function(Item item, int delta) onAdjust;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebar;
    final gutter = wide ? Insets.pageWide : Insets.pageNarrow;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Cards stay legible at roughly 260-340px; the column count follows
        // from the space rather than from a fixed breakpoint table.
        final available = constraints.maxWidth - gutter * 2;
        final columns = (available / 290).floor().clamp(1, 4);
        const gap = Insets.md;
        final cardWidth = (available - gap * (columns - 1)) / columns;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Insets.section),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: cardWidth,
                      child: ProductCard(
                        item: item,
                        currency: settings.currency,
                        categoryColor: settings.colorFor(item.category),
                        // A row whose id is blank cannot be opened — the URL would be
                        // /items/ and matches no route — so it is not offered as
                        // if it could be. Rows like that predate the fix that
                        // stopped the server accepting an empty id, and erasing
                        // is what clears them.
                        onTap: item.id.isEmpty
                            ? null
                            : () => context.go('/items/${item.id}'),
                        onAdjust: (delta) => onAdjust(item, delta),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              Text(
                items.length == 1 ? '1 item' : '${number(items.length)} items',
                style: TextStyle(fontSize: 13, color: context.palette.inkMuted),
              ),
            ],
          ),
        );
      },
    );
  }
}
