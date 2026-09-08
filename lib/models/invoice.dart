import 'receipt.dart';

/// Where a credit sale has got to.
///
/// An invoice is raised when goods go out on account, and closes when the
/// money arrives. It is never edited once issued — a mistake is cancelled and
/// re-raised — so the document always reads as what was actually billed.
enum InvoiceStatus { open, partPaid, paid, cancelled }

InvoiceStatus invoiceStatusFrom(String? raw) => InvoiceStatus.values.firstWhere(
  (s) => s.name == raw,
  orElse: () => InvoiceStatus.open,
);

extension InvoiceStatusLabel on InvoiceStatus {
  String get label => switch (this) {
    InvoiceStatus.open => 'Unpaid',
    InvoiceStatus.partPaid => 'Part paid',
    InvoiceStatus.paid => 'Paid',
    InvoiceStatus.cancelled => 'Cancelled',
  };

  /// Whether the invoice still counts as a sale. A cancellation is struck off
  /// entirely; everything else stands, paid or not.
  bool get countsAsSale => this != InvoiceStatus.cancelled;

  /// Whether money can still be taken against it.
  bool get isCollectable =>
      this == InvoiceStatus.open || this == InvoiceStatus.partPaid;
}

class InvoiceLine {
  const InvoiceLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    this.sku = '',
    this.unit = 'pcs',
    required this.quantity,
    this.unitPrice = 0,
    this.discount = 0,
    this.costOfGoods = 0,
  });

  final String id;
  final String itemId;

  /// Denormalised so a historical invoice stays readable — and reprintable —
  /// after the item is deleted from the catalogue.
  final String itemName;
  final String sku;
  final String unit;

  final int quantity;
  final double unitPrice;

  /// Money off this line, as an amount rather than a rate.
  final double discount;

  /// What the goods cost, banked when they left the shelf, so margin survives
  /// later movement in the item's average cost.
  final double costOfGoods;

  double get gross => quantity * unitPrice;

  double get net => (gross - discount).clamp(0, double.infinity).toDouble();

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'itemName': itemName,
    'sku': sku,
    'unit': unit,
    'quantity': quantity,
    'unitPrice': unitPrice,
    'discount': discount,
    'costOfGoods': costOfGoods,
  };
}

/// A demand for payment for goods already handed over on credit.
///
/// The counterpart to a receipt, and deliberately the same shape: the two
/// differ in when the money arrives, not in what was sold. As with a receipt,
/// [movesStock] records whether issuing it is what took the goods off the
/// shelf — false when it bills a sales order that already despatched — and it
/// is what a cancellation reads to decide whether stock comes back.
///
/// Payments are recorded as receipts pointing at this invoice, so a customer
/// paying in instalments gets a receipt for each one and the invoice tracks
/// the running balance.
class Invoice {
  const Invoice({
    required this.id,
    required this.reference,
    this.salesOrderId,
    this.customerId,
    this.customerName = '',
    this.status = InvoiceStatus.open,
    this.lines = const [],
    this.discount = 0,
    this.taxRate = 0,
    this.taxLabel = 'Tax',
    this.amountPaid = 0,
    this.terms = '',
    this.notes = '',
    this.movesStock = true,
    required this.issuedAt,
    this.dueAt,
    this.closedAt,
    this.cancelledReason = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String reference;

  /// Set when the invoice bills a sales order rather than standing alone.
  final String? salesOrderId;

  final String? customerId;
  final String customerName;
  final InvoiceStatus status;
  final List<InvoiceLine> lines;

  /// Money off the whole bill, on top of any per-line discounts.
  final double discount;

  /// Frozen at the moment of issue, so changing the rate in settings never
  /// rewrites what a customer was actually billed.
  final double taxRate;
  final String taxLabel;

  /// Kept in step by the controller as payments are recorded, so a screen can
  /// read a balance without gathering every receipt first.
  final double amountPaid;

  /// Free text such as "30 days net" — what was agreed, printed on the page.
  final String terms;

  final String notes;

  /// Whether issuing this invoice is what took the stock off the shelf.
  final bool movesStock;

  final DateTime issuedAt;
  final DateTime? dueAt;
  final DateTime? closedAt;
  final String cancelledReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  // --- Money ---------------------------------------------------------------

  double get gross => lines.fold(0.0, (sum, l) => sum + l.gross);

  double get lineDiscount => lines.fold(0.0, (sum, l) => sum + l.discount);

  /// Capped at the goods themselves, so an over-generous discount can never
  /// make an invoice negative.
  double get discountTotal =>
      (lineDiscount + discount).clamp(0, gross <= 0 ? 0 : gross).toDouble();

  /// What tax is charged on, and the revenue figure margin is measured from.
  double get subtotal =>
      (gross - discountTotal).clamp(0, double.infinity).toDouble();

  double get tax => subtotal * taxRate;

  double get total => subtotal + tax;

  double get balanceDue =>
      (total - amountPaid).clamp(0, double.infinity).toDouble();

  /// Rounded to the currency's smallest sensible step, so a total of
  /// 4999.999999 from a percentage tax does not read as unpaid forever.
  bool get isSettled => balanceDue < 0.005;

  /// Revenue this invoice represents, before tax and net of cancellation —
  /// recognised when the goods went out, not when the money arrives.
  double get revenue => status.countsAsSale ? subtotal : 0;

  double get costOfGoods => status.countsAsSale
      ? lines.fold(0.0, (sum, l) => sum + l.costOfGoods)
      : 0;

  double get grossProfit => revenue - costOfGoods;

  double? get marginRate => revenue <= 0 ? null : grossProfit / revenue;

  /// Money still owed on a live invoice — what the business is waiting on.
  double get outstanding => status.countsAsSale ? balanceDue : 0;

  int get units => lines.fold(0, (sum, l) => sum + l.quantity);

  /// Past its due date with money still owed.
  bool get isOverdue {
    final due = dueAt;
    if (due == null || !status.isCollectable) return false;
    return due.isBefore(DateTime.now()) && !isSettled;
  }

  /// Whole days past due, for an ageing breakdown. Zero when not overdue.
  int get daysOverdue {
    final due = dueAt;
    if (due == null || !isOverdue) return 0;
    return DateTime.now().difference(due).inDays;
  }

  Invoice copyWith({
    InvoiceStatus? status,
    List<InvoiceLine>? lines,
    double? amountPaid,
    String? notes,
    DateTime? dueAt,
    DateTime? closedAt,
    String? cancelledReason,
    DateTime? updatedAt,
  }) {
    return Invoice(
      id: id,
      reference: reference,
      salesOrderId: salesOrderId,
      customerId: customerId,
      customerName: customerName,
      status: status ?? this.status,
      lines: lines ?? this.lines,
      discount: discount,
      taxRate: taxRate,
      taxLabel: taxLabel,
      amountPaid: amountPaid ?? this.amountPaid,
      terms: terms,
      notes: notes ?? this.notes,
      movesStock: movesStock,
      issuedAt: issuedAt,
      dueAt: dueAt ?? this.dueAt,
      closedAt: closedAt ?? this.closedAt,
      cancelledReason: cancelledReason ?? this.cancelledReason,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'reference': reference,
    'salesOrderId': salesOrderId,
    'customerId': customerId,
    'customerName': customerName,
    'status': status.name,
    'lines': [for (final l in lines) l.toJson()],
    'discount': discount,
    'taxRate': taxRate,
    'taxLabel': taxLabel,
    'amountPaid': amountPaid,
    'terms': terms,
    'notes': notes,
    'movesStock': movesStock,
    'issuedAt': issuedAt.toIso8601String(),
    'dueAt': dueAt?.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'cancelledReason': cancelledReason,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'subtotal': subtotal,
    'tax': tax,
    'total': total,
    'balanceDue': balanceDue,
  };
}

/// One payment against an invoice, as it is shown on the invoice's own page.
/// The receipt is the record; this is the view of it the invoice needs.
class InvoicePayment {
  const InvoicePayment({
    required this.receiptId,
    required this.reference,
    required this.amount,
    required this.method,
    required this.at,
  });

  final String receiptId;
  final String reference;
  final double amount;
  final PaymentMethod method;
  final DateTime at;
}
