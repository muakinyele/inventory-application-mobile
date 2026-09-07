import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import '../data/receipt_document.dart';
import '../models/receipt.dart';
import '../state/inventory_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/page_header.dart';
import 'widgets/stat_card.dart';
import 'widgets/status_pill.dart';

/// `null` is the "All" pill.
typedef _StatusFilter = ReceiptStatus?;

class ReceiptsPage extends StatefulWidget {
  const ReceiptsPage({super.key});

  @override
  State<ReceiptsPage> createState() => _ReceiptsPageState();
}

class _ReceiptsPageState extends State<ReceiptsPage> {
  _StatusFilter _status;
  final _search = TextEditingController();

  _ReceiptsPageState() : _status = null;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Exports whatever the filters are currently showing, rather than the whole
  /// book — a day's takings or one customer's receipts is what an export is
  /// usually wanted for.
  Future<void> _exportVisible(
    Rect? origin,
    List<Receipt> visible,
    bool asJson,
  ) async {
    final controller = context.read<InventoryController>();
    if (visible.isEmpty) {
      _notify('Nothing to export with those filters.');
      return;
    }
    final settings = controller.settings;
    await const ExportService().shareText(
      filename: asJson ? 'receipts.json' : 'receipts.csv',
      contents: asJson
          ? receiptsToJson(visible, settings)
          : receiptsToCsv(visible, settings),
      mimeType: asJson ? 'application/json' : 'text/csv',
      originRect: origin,
    );
    if (mounted) {
      _notify('${number(visible.length)} receipts exported');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    final all = controller.receipts;
    final query = _search.text.trim().toLowerCase();
    final visible = all.where((r) {
      if (_status != null && r.status != _status) return false;
      if (query.isEmpty) return true;
      return r.reference.toLowerCase().contains(query) ||
          r.customerName.toLowerCase().contains(query) ||
          r.lines.any((l) => l.itemName.toLowerCase().contains(query));
    }).toList();

    final today = DateTime.now();
    final todays = all.where((r) => _sameDay(r.issuedAt, today)).toList();
    final owed = controller.unpaidReceipts.fold(
      0.0,
      (sum, r) => sum + r.balanceDue,
    );
    final refunded = all.fold(0.0, (sum, r) => sum + r.refundTotal);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Receipts',
              subtitle: 'What was sold across the counter, and what it took',
              actions: [
                if (all.isNotEmpty)
                  Builder(
                    builder: (buttonContext) => OutlinedButton.icon(
                      onPressed: () =>
                          _openExportMenu(buttonContext, visible),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Export'),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: () => context.go('/receipts/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Receipt'),
                ),
              ],
            ),
            if (all.isNotEmpty) ...[
              StatGrid(
                cards: [
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(
                      todays.fold(0.0, (sum, r) => sum + r.netTotal),
                      currency,
                    ),
                    label: "Today's takings",
                    tone: StatTone.good,
                  ),
                  StatCard(
                    icon: Icons.receipt_long_outlined,
                    value: number(todays.length),
                    label: 'Receipts today',
                  ),
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(owed, currency),
                    label: 'Owed',
                    tone: owed > 0 ? StatTone.critical : StatTone.neutral,
                  ),
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(refunded, currency),
                    label: 'Refunded',
                    tone: refunded > 0
                        ? StatTone.warning
                        : StatTone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search by reference, customer or item',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(_search.clear),
                        ),
                ),
              ),
              const SizedBox(height: Insets.md),
              FilterChips<_StatusFilter>(
                selected: _status,
                onSelected: (value) => setState(() => _status = value),
                options: const [
                  FilterOption(null, 'All'),
                  FilterOption(ReceiptStatus.issued, 'Issued'),
                  FilterOption(
                    ReceiptStatus.partRefunded,
                    'Part refunded',
                  ),
                  FilterOption(ReceiptStatus.refunded, 'Refunded'),
                  FilterOption(ReceiptStatus.voided, 'Voided'),
                ],
              ),
              const SizedBox(height: Insets.lg),
            ],
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: all.isEmpty
                      ? 'No receipts yet'
                      : 'Nothing matches',
                  body: all.isEmpty
                      ? 'Raise a receipt to record a counter sale. It takes '
                            'the stock off the shelf and gives the customer '
                            'something to take away.'
                      : 'Try another filter, or clear the search.',
                  action: all.isEmpty
                      ? FilledButton.icon(
                          onPressed: () => context.go('/receipts/new'),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('New Receipt'),
                        )
                      : OutlinedButton(
                          onPressed: () => setState(() {
                            _status = null;
                            _search.clear();
                          }),
                          child: const Text('Show all'),
                        ),
                ),
              )
            else
              for (final receipt in visible) ...[
                _ReceiptCard(receipt: receipt, currency: currency),
                const SizedBox(height: Insets.md),
              ],
          ],
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _openExportMenu(
    BuildContext buttonContext,
    List<Receipt> visible,
  ) async {
    // Read before the sheet opens: the button it anchors to may be gone by
    // the time the sheet closes, and iPadOS needs the rect.
    final origin = shareOriginOf(buttonContext);
    final asJson = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) {
        final p = sheetContext.palette;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xl,
                  Insets.md,
                  Insets.xl,
                  Insets.sm,
                ),
                child: Text(
                  'Export ${number(visible.length)} receipts',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Insets.xl,
                ),
                leading: Icon(Icons.table_chart_outlined, color: p.accent),
                title: const Text(
                  'Spreadsheet (CSV)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'One row per line, for the books',
                  style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                ),
                onTap: () => Navigator.of(sheetContext).pop(false),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Insets.xl,
                ),
                leading: Icon(Icons.data_object_outlined, color: p.accent),
                title: const Text(
                  'Data file (JSON)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Every field, for another system',
                  style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                ),
                onTap: () => Navigator.of(sheetContext).pop(true),
              ),
              const SizedBox(height: Insets.sm),
            ],
          ),
        );
      },
    );
    if (asJson == null || !mounted) return;
    await _exportVisible(origin, visible, asJson);
  }
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.receipt, required this.currency});

  final Receipt receipt;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final voided = receipt.status == ReceiptStatus.voided;

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
          onTap: () => context.go('/receipts/${receipt.id}'),
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      receipt.reference,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                        decoration: voided
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    Flexible(
                      child: ReceiptStatusPill(
                        status: receipt.status,
                        unpaid: !receipt.isPaid &&
                            receipt.status.countsAsSale &&
                            !receipt.method.isDeferred,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      money(receipt.netTotal, currency),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: voided ? p.inkMuted : p.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    receipt.customerName.isEmpty
                        ? 'Walk-in'
                        : receipt.customerName,
                    receipt.method.label,
                    receipt.lines.length == 1
                        ? '1 line'
                        : '${receipt.lines.length} lines',
                    dateTimeLabel(receipt.issuedAt),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.inkMuted),
                ),
                if (receipt.balanceDue > 0 && receipt.status.countsAsSale) ...[
                  const SizedBox(height: Insets.sm),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        size: 13,
                        color: p.warningText,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${money(receipt.balanceDue, currency)} still owed',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.warningText,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
