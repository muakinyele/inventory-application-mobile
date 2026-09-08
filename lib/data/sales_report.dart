import 'package:intl/intl.dart';

import '../models/invoice.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';

/// The spans a report can be run over.
enum ReportPeriod { daily, weekly, monthly, yearly, custom }

extension ReportPeriodLabel on ReportPeriod {
  String get label => switch (this) {
    ReportPeriod.daily => 'Daily',
    ReportPeriod.weekly => 'Weekly',
    ReportPeriod.monthly => 'Monthly',
    ReportPeriod.yearly => 'Yearly',
    ReportPeriod.custom => 'Custom',
  };

  /// What one step of this period covers, for the "previous period" compare.
  String get unit => switch (this) {
    ReportPeriod.daily => 'day',
    ReportPeriod.weekly => 'week',
    ReportPeriod.monthly => 'month',
    ReportPeriod.yearly => 'year',
    ReportPeriod.custom => 'period',
  };
}

/// A half-open date span: [start] inclusive, [end] exclusive.
///
/// Half-open so adjacent periods tile without overlapping — a sale at exactly
/// midnight belongs to the day starting then, and to only one period.
class ReportRange {
  const ReportRange(this.start, this.end, this.label);

  final DateTime start;
  final DateTime end;
  final String label;

  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  /// The last day the range covers — [end] is exclusive, so a report titled
  /// "1–31 March" ends at 1 April.
  DateTime get lastDay => end.subtract(const Duration(days: 1));

  static final _day = DateFormat('d MMM yyyy');
  static final _month = DateFormat('MMMM yyyy');

  /// Resolves a period around [anchor] into concrete dates.
  ///
  /// Weeks run Monday to Sunday, which is what a business week means here and
  /// what `DateTime.weekday` numbers from.
  static ReportRange of(ReportPeriod period, DateTime anchor) {
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    return switch (period) {
      ReportPeriod.daily => ReportRange(
        day,
        day.add(const Duration(days: 1)),
        _day.format(day),
      ),
      ReportPeriod.weekly => () {
        final monday = day.subtract(Duration(days: day.weekday - 1));
        final sunday = monday.add(const Duration(days: 6));
        return ReportRange(
          monday,
          monday.add(const Duration(days: 7)),
          '${_day.format(monday)} – ${_day.format(sunday)}',
        );
      }(),
      ReportPeriod.monthly => () {
        final first = DateTime(day.year, day.month);
        return ReportRange(
          first,
          DateTime(day.year, day.month + 1),
          _month.format(first),
        );
      }(),
      ReportPeriod.yearly => ReportRange(
        DateTime(day.year),
        DateTime(day.year + 1),
        '${day.year}',
      ),
      ReportPeriod.custom => ReportRange(
        day,
        day.add(const Duration(days: 1)),
        _day.format(day),
      ),
    };
  }

  /// A custom span between two chosen days, both inclusive as the user picked
  /// them — [end] is pushed to the following midnight so the last day counts.
  static ReportRange between(DateTime from, DateTime to) {
    final start = DateTime(from.year, from.month, from.day);
    final last = DateTime(to.year, to.month, to.day);
    final end = last.add(const Duration(days: 1));
    return ReportRange(
      start,
      end.isAfter(start) ? end : start.add(const Duration(days: 1)),
      start == last
          ? _day.format(start)
          : '${_day.format(start)} – ${_day.format(last)}',
    );
  }
}

/// Where a sale came from. Kept on the report so a figure can be traced back
/// to the kind of document that produced it.
enum SaleSource { counter, credit, salesOrder }

extension SaleSourceLabel on SaleSource {
  String get label => switch (this) {
    SaleSource.counter => 'Counter sales',
    SaleSource.credit => 'Credit sales',
    SaleSource.salesOrder => 'Sales orders',
  };
}

/// One item's trading figures over the period.
class ReportLine {
  const ReportLine({
    required this.itemId,
    required this.itemName,
    required this.sku,
    required this.unitsSold,
    required this.revenue,
    required this.costOfGoods,
  });

  final String itemId;
  final String itemName;
  final String sku;
  final int unitsSold;

  /// Net of discounts and before tax. Tax is collected on someone else's
  /// behalf, so counting it as revenue would inflate both the top line and
  /// the margin.
  final double revenue;

  final double costOfGoods;

  double get grossProfit => revenue - costOfGoods;

  /// Null rather than zero when nothing sold, so a screen shows '—' instead
  /// of a margin that was never earned.
  double? get marginRate => revenue <= 0 ? null : grossProfit / revenue;
}

/// Revenue, cost and margin over a period, per item and in total.
///
/// The one rule that keeps the figures honest: **a sale is counted where the
/// goods left the shelf, exactly once**. Three kinds of document can do that —
/// a counter receipt, a credit invoice, and a despatch against a sales order —
/// and each carries a `movesStock` flag saying whether it was the one that
/// moved it. Paperwork raised on top (a receipt for an invoice payment, an
/// invoice billing a sales order) moves nothing and is deliberately ignored
/// here, or the same goods would be counted two and three times over.
///
/// Revenue is recognised when the goods go out, not when the money arrives,
/// so a credit sale counts in full on the day it was invoiced and the unpaid
/// balance shows separately as [outstanding].
class SalesReport {
  const SalesReport({
    required this.range,
    required this.lines,
    required this.revenueBySource,
    required this.outstanding,
    required this.creditSales,
    required this.documentCount,
    required this.currency,
  });

  final ReportRange range;

  /// Per item, biggest gross profit first.
  final List<ReportLine> lines;

  final Map<SaleSource, double> revenueBySource;

  /// Money billed in this period and not yet collected.
  final double outstanding;

  /// How many of the documents in the period were credit sales.
  final int creditSales;

  final int documentCount;
  final String currency;

  double get revenue => lines.fold(0.0, (sum, l) => sum + l.revenue);
  double get costOfGoods => lines.fold(0.0, (sum, l) => sum + l.costOfGoods);
  double get grossProfit => revenue - costOfGoods;
  double? get marginRate => revenue <= 0 ? null : grossProfit / revenue;
  int get unitsSold => lines.fold(0, (sum, l) => sum + l.unitsSold);

  bool get isEmpty => lines.isEmpty;

  /// Builds the report. [salesOrderDate] resolves when a sales order's
  /// revenue is recognised — see the note on [_salesOrderDate].
  static SalesReport build({
    required ReportRange range,
    required List<Receipt> receipts,
    required List<Invoice> invoices,
    required List<SalesOrder> salesOrders,
    required String currency,
  }) {
    final totals = <String, _Accumulator>{};
    final bySource = <SaleSource, double>{};
    var documents = 0;
    var creditSales = 0;
    var outstanding = 0.0;

    void addLine(
      SaleSource source,
      String itemId,
      String itemName,
      String sku,
      int units,
      double revenue,
      double cost,
    ) {
      final acc = totals.putIfAbsent(
        // Items deleted from the catalogue still have to report, so the name
        // is the fallback key rather than dropping the row.
        itemId.isEmpty ? 'name:$itemName' : itemId,
        () => _Accumulator(itemId, itemName, sku),
      );
      acc.units += units;
      acc.revenue += revenue;
      acc.cost += cost;
      bySource[source] = (bySource[source] ?? 0) + revenue;
    }

    // --- Counter sales -----------------------------------------------------
    for (final receipt in receipts) {
      // movesStock is false for a receipt that only records a payment, and
      // countsAsSale is false for a void. Both are excluded here.
      if (!receipt.movesStock || !receipt.status.countsAsSale) continue;
      if (!range.contains(receipt.issuedAt)) continue;
      documents++;

      // Refunds net down what the customer kept, and the bill-level discount
      // is shared across the lines it was taken off, so per-item revenue sums
      // back to the receipt's own subtotal.
      final netOfLines = receipt.lines.fold(0.0, (sum, l) => sum + l.net);
      final scale = netOfLines <= 0 ? 0.0 : receipt.subtotal / netOfLines;

      for (final line in receipt.lines) {
        if (line.quantityKept <= 0) continue;
        final kept = line.quantity <= 0
            ? 0.0
            : line.quantityKept / line.quantity;
        addLine(
          SaleSource.counter,
          line.itemId,
          line.itemName,
          line.sku,
          line.quantityKept,
          line.net * kept * scale,
          line.costOfGoods * kept,
        );
      }
      if (receipt.balanceDue > 0) outstanding += receipt.balanceDue;
    }

    // --- Credit sales ------------------------------------------------------
    for (final invoice in invoices) {
      if (!invoice.movesStock || !invoice.status.countsAsSale) continue;
      if (!range.contains(invoice.issuedAt)) continue;
      documents++;
      creditSales++;

      final netOfLines = invoice.lines.fold(0.0, (sum, l) => sum + l.net);
      final scale = netOfLines <= 0 ? 0.0 : invoice.subtotal / netOfLines;

      for (final line in invoice.lines) {
        addLine(
          SaleSource.credit,
          line.itemId,
          line.itemName,
          line.sku,
          line.quantity,
          line.net * scale,
          line.costOfGoods,
        );
      }
      outstanding += invoice.outstanding;
    }

    // --- Sales orders ------------------------------------------------------
    for (final order in salesOrders) {
      if (order.status == SalesStatus.cancelled) continue;
      if (order.unitsFulfilled <= 0) continue;
      final at = _salesOrderDate(order);
      if (!range.contains(at)) continue;
      // An order that has been receipted or invoiced is still the document
      // that moved the stock — the paperwork on top was skipped above — so it
      // is counted here and nowhere else.
      documents++;

      for (final line in order.lines) {
        if (line.quantityFulfilled <= 0) continue;
        addLine(
          SaleSource.salesOrder,
          line.itemId,
          line.itemName,
          '',
          line.quantityFulfilled,
          line.revenue,
          line.costOfGoods,
        );
      }
    }

    final lines =
        totals.values
            .map(
              (a) => ReportLine(
                itemId: a.itemId,
                itemName: a.itemName,
                sku: a.sku,
                unitsSold: a.units,
                revenue: a.revenue,
                costOfGoods: a.cost,
              ),
            )
            .where((l) => l.unitsSold > 0 || l.revenue != 0)
            .toList()
          ..sort((a, b) {
            final byProfit = b.grossProfit.compareTo(a.grossProfit);
            return byProfit != 0
                ? byProfit
                : a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
          });

    return SalesReport(
      range: range,
      lines: lines,
      revenueBySource: bySource,
      outstanding: outstanding,
      creditSales: creditSales,
      documentCount: documents,
      currency: currency,
    );
  }

  /// When a sales order's revenue is recognised.
  ///
  /// Its despatches are not individually dated — the lines carry quantities,
  /// not timestamps — so the whole order is recognised on the date it was
  /// agreed. For an order confirmed and sent in one period this is exact; for
  /// one despatched across a period boundary the revenue lands in the period
  /// the sale was made, which is the convention a set of accounts uses anyway.
  static DateTime _salesOrderDate(SalesOrder order) =>
      order.confirmedAt ?? order.createdAt;
}

class _Accumulator {
  _Accumulator(this.itemId, this.itemName, this.sku);

  final String itemId;
  final String itemName;
  String sku;
  int units = 0;
  double revenue = 0;
  double cost = 0;
}
