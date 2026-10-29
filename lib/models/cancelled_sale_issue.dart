/// A cancelled sale that is not fully unwound, as the server's scan finds it:
/// stock it sent is still out, or an invoice billing it is still live.
///
/// These come from sales cancelled before cancelling returned stock.
class CancelledSaleIssue {
  const CancelledSaleIssue({
    required this.salesOrderId,
    required this.salesOrderReference,
    this.customerName = '',
    this.stockOut = const [],
    this.liveInvoices = const [],
    this.paidBy = const [],
  });

  factory CancelledSaleIssue.fromJson(Map<String, dynamic> json) =>
      CancelledSaleIssue(
        salesOrderId: json['salesOrderId'] as String,
        salesOrderReference: json['salesOrderReference'] as String? ?? '',
        customerName: json['customerName'] as String? ?? '',
        stockOut: [
          for (final raw in (json['stockOut'] as List? ?? const []))
            (
              itemId: (raw as Map)['itemId'] as String,
              itemName: raw['itemName'] as String? ?? '',
              quantity: (raw['quantity'] as num).toInt(),
            ),
        ],
        liveInvoices: [
          for (final raw in (json['liveInvoices'] as List? ?? const []))
            (
              id: (raw as Map)['id'] as String,
              reference: raw['reference'] as String? ?? '',
              amountPaid: (raw['amountPaid'] as num? ?? 0).toDouble(),
            ),
        ],
        paidBy: [
          for (final r in (json['paidBy'] as List? ?? const [])) r as String,
        ],
      );

  final String salesOrderId;
  final String salesOrderReference;
  final String customerName;
  final List<({String itemId, String itemName, int quantity})> stockOut;
  final List<({String id, String reference, double amountPaid})> liveInvoices;

  /// Payments that block a repair. Empty means it can be fixed.
  final List<String> paidBy;

  bool get fixable => paidBy.isEmpty;

  int get unitsOut => stockOut.fold(0, (sum, line) => sum + line.quantity);
}
