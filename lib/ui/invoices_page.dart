import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/formatters.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import '../data/invoice_document.dart';
import '../models/invoice.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/filter_chips.dart';
import 'widgets/page_header.dart';
import 'widgets/pagination.dart';
import 'widgets/stat_card.dart';
import 'widgets/status_pill.dart';

/// `null` is the "All" pill.
typedef _StatusFilter = InvoiceStatus?;

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key});

  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  _StatusFilter _status;
  final _search = TextEditingController();

  /// Where in the list the reader is. Every control that changes what is in
  /// the list goes through [_refine], which returns to the first page — a
  /// search typed on page 4 has to land on its matches.
  PageCursor _cursor = const PageCursor();

  void _refine(VoidCallback change) {
    setState(() {
      change();
      _cursor = _cursor.withPage(0);
    });
  }

  _InvoicesPageState() : _status = null;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _notify(
    String message, {
    MessageTone tone = MessageTone.success,
  }) {
    return showAppMessage(context, message, tone: tone);
  }

  Future<void> _export(Rect? origin, List<Invoice> visible) async {
    if (visible.isEmpty) {
      _notify(
        'Nothing to export with those filters.',
        tone: MessageTone.warning,
      );
      return;
    }
    await const ExportService().shareText(
      filename: 'invoices.csv',
      contents: invoicesToCsv(visible),
      mimeType: 'text/csv',
      originRect: origin,
    );
    if (mounted) _notify('${number(visible.length)} invoices exported');
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();
    final currency = controller.settings.currency;
    final p = context.palette;

    final all = controller.invoices;
    final query = _search.text.trim().toLowerCase();
    final visible = all.where((i) {
      if (_status != null && i.status != _status) return false;
      if (query.isEmpty) return true;
      return i.reference.toLowerCase().contains(query) ||
          i.customerName.toLowerCase().contains(query) ||
          i.lines.any((l) => l.itemName.toLowerCase().contains(query));
    }).toList();
    final cursor = _cursor.clamped(visible.length);

    final owed = controller.totalReceivable;
    final overdue = controller.overdueInvoices;
    final overdueValue = overdue.fold(0.0, (sum, i) => sum + i.outstanding);
    final billed = all
        .where((i) => i.status.countsAsSale)
        .fold(0.0, (sum, i) => sum + i.total);

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: PageBody(
          children: [
            PageHeader(
              title: 'Invoices',
              subtitle: 'Credit sales, and what is still owed on them',
              actions: [
                if (all.isNotEmpty)
                  Builder(
                    builder: (buttonContext) => OutlinedButton.icon(
                      onPressed: () =>
                          _export(shareOriginOf(buttonContext), visible),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Export'),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: () => context.go('/invoices/new'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Invoice'),
                ),
              ],
            ),
            if (all.isNotEmpty) ...[
              StatGrid(
                cards: [
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(owed, currency),
                    label: 'Owed to you',
                    tone: owed > 0 ? StatTone.warning : StatTone.neutral,
                  ),
                  StatCard(
                    icon: Icons.description_outlined,
                    value: number(controller.openInvoices.length),
                    label: 'Unpaid invoices',
                  ),
                  StatCard(
                    icon: Icons.priority_high_rounded,
                    value: moneyCompact(overdueValue, currency),
                    label: 'Overdue',
                    tone: overdue.isEmpty
                        ? StatTone.neutral
                        : StatTone.critical,
                  ),
                  StatCard(
                    glyph: currencySymbol(currency),
                    value: moneyCompact(billed, currency),
                    label: 'Billed all time',
                    tone: StatTone.good,
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _search,
                onChanged: (_) => _refine(() {}),
                decoration: InputDecoration(
                  hintText: 'Search by reference, customer or item',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => _refine(_search.clear),
                        ),
                ),
              ),
              const SizedBox(height: Insets.md),
              FilterChips<_StatusFilter>(
                selected: _status,
                onSelected: (value) => _refine(() => _status = value),
                options: const [
                  FilterOption(null, 'All'),
                  FilterOption(InvoiceStatus.open, 'Unpaid'),
                  FilterOption(InvoiceStatus.partPaid, 'Part paid'),
                  FilterOption(InvoiceStatus.paid, 'Paid'),
                  FilterOption(InvoiceStatus.cancelled, 'Cancelled'),
                ],
              ),
              const SizedBox(height: Insets.lg),
            ],
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Insets.section),
                child: EmptyState(
                  icon: Icons.description_outlined,
                  title: all.isEmpty ? 'No invoices yet' : 'Nothing matches',
                  body: all.isEmpty
                      ? 'Raise an invoice when goods go out on account. It '
                            'takes the stock off the shelf now, and tracks '
                            'what the customer owes until they pay.'
                      : 'Try another filter, or clear the search.',
                  action: all.isEmpty
                      ? FilledButton.icon(
                          onPressed: () => context.go('/invoices/new'),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('New Invoice'),
                        )
                      : OutlinedButton(
                          onPressed: () => _refine(() {
                            _status = null;
                            _search.clear();
                          }),
                          child: const Text('Show all'),
                        ),
                ),
              )
            else
              // The PAGE, not the whole list. Export still takes `visible`,
              // so "export what you are looking at" keeps meaning the whole
              // filtered set rather than whichever page is on screen.
              for (final invoice in cursor.slice(visible)) ...[
                _InvoiceCard(invoice: invoice, currency: currency),
                const SizedBox(height: Insets.md),
              ],
            PaginationBar(
              cursor: cursor,
              total: visible.length,
              unit: 'invoices',
              unfilteredTotal: all.length,
              filtered: visible.length != all.length,
              onCursor: (next) => setState(() => _cursor = next),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({required this.invoice, required this.currency});

  final Invoice invoice;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final cancelled = invoice.status == InvoiceStatus.cancelled;
    final collected = invoice.total <= 0
        ? 0.0
        : (invoice.amountPaid / invoice.total).clamp(0.0, 1.0);

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
          onTap: () => context.go('/invoices/${invoice.id}'),
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      invoice.reference,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                        decoration: cancelled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    Flexible(
                      child: InvoiceStatusPill(
                        status: invoice.status,
                        overdue: invoice.isOverdue,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      money(invoice.total, currency),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: cancelled ? p.inkMuted : p.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    invoice.customerName.isEmpty
                        ? 'Account customer'
                        : invoice.customerName,
                    invoice.lines.length == 1
                        ? '1 line'
                        : '${invoice.lines.length} lines',
                    'issued ${dayLabel(invoice.issuedAt)}',
                    if (invoice.dueAt != null)
                      'due ${dayLabel(invoice.dueAt!)}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.inkMuted),
                ),
                if (!cancelled && invoice.balanceDue > 0) ...[
                  const SizedBox(height: Insets.md),
                  Row(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: p.surfaceSunken,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: constraints.maxWidth * collected,
                                decoration: BoxDecoration(
                                  color: p.good,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      Text(
                        '${money(invoice.balanceDue, currency)} owed',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: invoice.isOverdue ? p.critical : p.warningText,
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
