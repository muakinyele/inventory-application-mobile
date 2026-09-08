import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/sales_report.dart';
import 'empty_state.dart';
import 'stat_card.dart';

/// Picks the span a report covers: a preset period stepped backwards and
/// forwards, or a pair of dates chosen by hand.
class PeriodPicker extends StatelessWidget {
  const PeriodPicker({
    super.key,
    required this.period,
    required this.range,
    required this.onPeriodChanged,
    required this.onStep,
    required this.onPickCustom,
    required this.canStepForward,
  });

  final ReportPeriod period;
  final ReportRange range;
  final ValueChanged<ReportPeriod> onPeriodChanged;

  /// -1 for the previous period, +1 for the next.
  final ValueChanged<int> onStep;

  final VoidCallback onPickCustom;

  /// False once the range reaches today: there is nothing to report from the
  /// future, and letting it walk forward only invites confusion.
  final bool canStepForward;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final custom = period == ReportPeriod.custom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            for (final option in ReportPeriod.values)
              _PeriodChip(
                label: option.label,
                selected: option == period,
                onTap: () => onPeriodChanged(option),
              ),
          ],
        ),
        const SizedBox(height: Insets.md),
        Row(
          children: [
            if (!custom) ...[
              _StepButton(
                icon: Icons.chevron_left,
                tooltip: 'Previous ${period.unit}',
                onTap: () => onStep(-1),
              ),
              const SizedBox(width: Insets.sm),
            ],
            Expanded(
              child: custom
                  ? OutlinedButton.icon(
                      onPressed: onPickCustom,
                      icon: const Icon(Icons.date_range_outlined, size: 18),
                      label: Text(range.label),
                    )
                  : Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: Insets.md,
                      ),
                      decoration: BoxDecoration(
                        color: p.surfaceSunken,
                        borderRadius: BorderRadius.circular(Radii.control),
                      ),
                      child: Text(
                        range.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: p.ink,
                        ),
                      ),
                    ),
            ),
            if (!custom) ...[
              const SizedBox(width: Insets.sm),
              _StepButton(
                icon: Icons.chevron_right,
                tooltip: 'Next ${period.unit}',
                onTap: canStepForward ? () => onStep(1) : null,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _PeriodChip extends StatelessWidget {
  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.accent : p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: 9,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: selected ? p.accentInk : p.inkSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: p.surfaceSunken,
        disabledForegroundColor: p.inkMuted.withValues(alpha: 0.4),
      ),
    );
  }
}

/// The four figures the whole report exists to show.
class TradingSummary extends StatelessWidget {
  const TradingSummary({super.key, required this.report});

  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final currency = report.currency;
    final margin = report.marginRate;
    final loss = report.grossProfit < 0;

    return StatGrid(
      cards: [
        StatCard(
          glyph: currencySymbol(currency),
          value: moneyCompact(report.revenue, currency),
          label: 'Revenue',
          tone: StatTone.good,
        ),
        StatCard(
          icon: Icons.local_shipping_outlined,
          value: moneyCompact(report.costOfGoods, currency),
          label: 'Cost of Goods',
        ),
        StatCard(
          icon: loss ? Icons.trending_down_rounded : Icons.trending_up_rounded,
          value: moneyCompact(report.grossProfit, currency),
          label: 'Gross Profit',
          tone: loss ? StatTone.critical : StatTone.good,
        ),
        StatCard(
          icon: Icons.percent_rounded,
          value: margin == null ? '—' : '${(margin * 100).toStringAsFixed(1)}%',
          label: 'Profit Margin',
          tone: loss ? StatTone.critical : StatTone.good,
        ),
      ],
    );
  }
}

/// Revenue, cost, profit and margin for every item that sold in the period,
/// with the totals row the figures have to add up to.
class TradingTable extends StatelessWidget {
  const TradingTable({super.key, required this.report});

  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final currency = report.currency;

    if (report.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.lg),
        child: EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Nothing sold in this period',
          body:
              'Raise a receipt or an invoice, or send stock against a sale, '
              'and the trading figures will appear here.',
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Six columns of figures need real width. Below that the table
        // becomes a stack of per-item cards rather than something unreadable
        // squeezed sideways.
        if (constraints.maxWidth < 720) {
          return Column(
            children: [
              for (final (index, line) in report.lines.indexed) ...[
                if (index > 0) Divider(color: p.line, height: Insets.xl),
                _ItemCard(line: line, currency: currency),
              ],
              Divider(color: p.line, height: Insets.xl),
              _ItemCard.total(report: report),
            ],
          );
        }

        return Table(
          columnWidths: const {
            0: FlexColumnWidth(4),
            1: FlexColumnWidth(1.4),
            2: FlexColumnWidth(2),
            3: FlexColumnWidth(2),
            4: FlexColumnWidth(2),
            5: FlexColumnWidth(1.4),
          },
          children: [
            TableRow(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.line)),
              ),
              children: [
                _head('Item'),
                _head('Units', right: true),
                _head('Revenue', right: true),
                _head('Cost of Goods', right: true),
                _head('Gross Profit', right: true),
                _head('Margin', right: true),
              ],
            ),
            for (final line in report.lines)
              TableRow(
                children: [
                  _cell(
                    context,
                    line.itemName,
                    sub: line.sku.isEmpty ? null : line.sku,
                  ),
                  _cell(context, number(line.unitsSold), right: true),
                  _cell(context, money(line.revenue, currency), right: true),
                  _cell(
                    context,
                    money(line.costOfGoods, currency),
                    right: true,
                  ),
                  _cell(
                    context,
                    money(line.grossProfit, currency),
                    right: true,
                    tone: line.grossProfit < 0 ? p.critical : p.goodText,
                    bold: true,
                  ),
                  _cell(
                    context,
                    line.marginRate == null
                        ? '—'
                        : '${(line.marginRate! * 100).toStringAsFixed(1)}%',
                    right: true,
                    tone: (line.marginRate ?? 0) < 0 ? p.critical : null,
                  ),
                ],
              ),
            TableRow(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.lineStrong)),
              ),
              children: [
                _cell(context, 'Total', bold: true),
                _cell(
                  context,
                  number(report.unitsSold),
                  right: true,
                  bold: true,
                ),
                _cell(
                  context,
                  money(report.revenue, currency),
                  right: true,
                  bold: true,
                ),
                _cell(
                  context,
                  money(report.costOfGoods, currency),
                  right: true,
                  bold: true,
                ),
                _cell(
                  context,
                  money(report.grossProfit, currency),
                  right: true,
                  bold: true,
                  tone: report.grossProfit < 0 ? p.critical : p.goodText,
                ),
                _cell(
                  context,
                  report.marginRate == null
                      ? '—'
                      : '${(report.marginRate! * 100).toStringAsFixed(1)}%',
                  right: true,
                  bold: true,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static Widget _head(String text, {bool right = false}) => Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Text(
        text.toUpperCase(),
        textAlign: right ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: context.palette.inkMuted,
        ),
      ),
    ),
  );

  static Widget _cell(
    BuildContext context,
    String text, {
    bool right = false,
    bool bold = false,
    Color? tone,
    String? sub,
  }) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: right
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: tone ?? p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (sub != null)
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: p.inkMuted),
            ),
        ],
      ),
    );
  }
}

/// The narrow-window form of one table row.
class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.line, required this.currency}) : report = null;

  const _ItemCard.total({required this.report}) : line = null, currency = '';

  final ReportLine? line;
  final SalesReport? report;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isTotal = report != null;
    final name = isTotal ? 'Total' : line!.itemName;
    final code = isTotal ? '' : line!.sku;
    final money_ = isTotal ? report!.currency : currency;
    final units = isTotal ? report!.unitsSold : line!.unitsSold;
    final revenue = isTotal ? report!.revenue : line!.revenue;
    final cost = isTotal ? report!.costOfGoods : line!.costOfGoods;
    final profit = isTotal ? report!.grossProfit : line!.grossProfit;
    final margin = isTotal ? report!.marginRate : line!.marginRate;

    Widget pair(String label, String value, {Color? tone}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: p.inkMuted)),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: tone ?? p.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
            Text(
              '${number(units)} sold',
              style: TextStyle(fontSize: 12.5, color: p.inkMuted),
            ),
          ],
        ),
        if (code.isNotEmpty)
          Text(code, style: TextStyle(fontSize: 11.5, color: p.inkMuted)),
        const SizedBox(height: Insets.sm),
        Wrap(
          spacing: Insets.xl,
          runSpacing: Insets.sm,
          children: [
            pair('Revenue', money(revenue, money_)),
            pair('Cost of goods', money(cost, money_)),
            pair(
              'Gross profit',
              money(profit, money_),
              tone: profit < 0 ? p.critical : p.goodText,
            ),
            pair(
              'Margin',
              margin == null ? '—' : '${(margin * 100).toStringAsFixed(1)}%',
              tone: (margin ?? 0) < 0 ? p.critical : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// Where the period's revenue came from, and what of it is still owed.
class RevenueSources extends StatelessWidget {
  const RevenueSources({super.key, required this.report});

  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final currency = report.currency;
    final sources = [
      for (final source in SaleSource.values)
        if ((report.revenueBySource[source] ?? 0) != 0)
          (source, report.revenueBySource[source]!),
    ];

    if (sources.isEmpty && report.outstanding <= 0) {
      return Text(
        'No sales in this period.',
        style: TextStyle(fontSize: 13.5, color: p.inkMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (source, value) in sources) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    source.label,
                    style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
                  ),
                ),
                Text(
                  money(value, currency),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final fraction = report.revenue <= 0
                  ? 0.0
                  : (value / report.revenue).clamp(0.0, 1.0);
              return Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: p.surfaceSunken,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: constraints.maxWidth * fraction,
                      decoration: BoxDecoration(
                        color: source == SaleSource.credit
                            ? p.warning
                            : p.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
        if (report.outstanding > 0) ...[
          Divider(color: p.line, height: Insets.lg),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 15, color: p.warningText),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Billed but not yet collected',
                  style: TextStyle(fontSize: 13, color: p.inkSecondary),
                ),
              ),
              Text(
                money(report.outstanding, currency),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: p.warningText,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
