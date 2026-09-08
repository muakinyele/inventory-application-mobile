/// How a receipt was paid for.
enum PaymentMethod { cash, card, transfer, mobile, credit }

PaymentMethod paymentMethodFrom(String? raw) => PaymentMethod.values.firstWhere(
  (m) => m.name == raw,
  orElse: () => PaymentMethod.cash,
);

extension PaymentMethodLabel on PaymentMethod {
  String get label => switch (this) {
    PaymentMethod.cash => 'Cash',
    PaymentMethod.card => 'Card',
    PaymentMethod.transfer => 'Bank transfer',
    PaymentMethod.mobile => 'Mobile money',
    PaymentMethod.credit => 'On account',
  };

  /// Whether the money is expected later rather than at the counter. An
  /// account sale is legitimately unpaid, so the screens do not flag it.
  bool get isDeferred => this == PaymentMethod.credit;
}

/// Where a receipt has got to. A receipt is never edited once issued — a
/// mistake is voided and re-raised, and goods coming back are refunded — so
/// the document always reads as what was actually handed over.
enum ReceiptStatus { issued, partRefunded, refunded, voided }

ReceiptStatus receiptStatusFrom(String? raw) => ReceiptStatus.values.firstWhere(
  (s) => s.name == raw,
  orElse: () => ReceiptStatus.issued,
);

extension ReceiptStatusLabel on ReceiptStatus {
  String get label => switch (this) {
    ReceiptStatus.issued => 'Issued',
    ReceiptStatus.partRefunded => 'Part refunded',
    ReceiptStatus.refunded => 'Refunded',
    ReceiptStatus.voided => 'Voided',
  };

  /// Whether the document still counts towards takings. A void is struck off
  /// entirely; a refund keeps its history and nets down instead.
  bool get countsAsSale => this != ReceiptStatus.voided;

  /// Whether goods can still come back against it.
  bool get isRefundable =>
      this == ReceiptStatus.issued || this == ReceiptStatus.partRefunded;
}

class ReceiptLine {
  const ReceiptLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    this.sku = '',
    this.unit = 'pcs',
    required this.quantity,
    this.unitPrice = 0,
    this.discount = 0,
    this.quantityRefunded = 0,
    this.costOfGoods = 0,
  });

  final String id;
  final String itemId;

  /// Denormalised so a historical receipt stays readable — and reprintable —
  /// after the item is deleted from the catalogue.
  final String itemName;
  final String sku;
  final String unit;

  final int quantity;
  final double unitPrice;

  /// Money off this line, as an amount rather than a rate: a seller knocking
  /// something off at the counter thinks in naira, not percent.
  final double discount;

  final int quantityRefunded;

  /// What the goods on this line cost, banked when they left the shelf, so
  /// margin survives later movement in the item's average cost.
  final double costOfGoods;

  /// Before discount.
  double get gross => quantity * unitPrice;

  /// What the line actually adds to the bill.
  double get net => (gross - discount).clamp(0, double.infinity);

  int get quantityKept => (quantity - quantityRefunded).clamp(0, quantity);

  bool get isFullyRefunded => quantityRefunded >= quantity;

  /// Value handed back, discount shared out over the units so a part refund
  /// of a discounted line gives back its fair share rather than list price.
  double get refundValue =>
      quantity <= 0 ? 0 : net * quantityRefunded / quantity;

  /// What the customer is left having paid for this line.
  double get netKept => net - refundValue;

  ReceiptLine copyWith({int? quantityRefunded, double? costOfGoods}) {
    return ReceiptLine(
      id: id,
      itemId: itemId,
      itemName: itemName,
      sku: sku,
      unit: unit,
      quantity: quantity,
      unitPrice: unitPrice,
      discount: discount,
      quantityRefunded: quantityRefunded ?? this.quantityRefunded,
      costOfGoods: costOfGoods ?? this.costOfGoods,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'itemName': itemName,
    'sku': sku,
    'unit': unit,
    'quantity': quantity,
    'unitPrice': unitPrice,
    'discount': discount,
    'quantityRefunded': quantityRefunded,
    'costOfGoods': costOfGoods,
  };
}

/// The document a customer is handed: what they bought, what it came to, and
/// what they paid.
///
/// Two things can raise one. A counter sale stands alone and takes the stock
/// off the shelf as it is issued. A receipt against a sales order is proof of
/// payment for goods that order already despatched, so it moves no stock —
/// [movesStock] records which of the two it was, and is what a void or a
/// refund reads to decide whether stock has to come back.
class Receipt {
  const Receipt({
    required this.id,
    required this.reference,
    this.salesOrderId,
    this.invoiceId,
    this.customerId,
    this.customerName = '',
    this.status = ReceiptStatus.issued,
    this.method = PaymentMethod.cash,
    this.lines = const [],
    this.discount = 0,
    this.taxRate = 0,
    this.taxLabel = 'Tax',
    this.amountPaid = 0,
    this.notes = '',
    this.cashier = '',
    this.movesStock = true,
    required this.issuedAt,
    this.refundedAt,
    this.voidedAt,
    this.voidReason = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String reference;

  /// Set when the receipt settles a sales order rather than standing alone.
  final String? salesOrderId;

  /// Set when the receipt is a payment against a credit sale. Such a receipt
  /// records money arriving for goods an invoice already billed, so it moves
  /// no stock and is never counted as revenue in its own right.
  final String? invoiceId;

  /// Whether this receipt is a payment against an invoice rather than a sale
  /// in its own right.
  bool get isInvoicePayment => invoiceId != null;

  final String? customerId;
  final String customerName;
  final ReceiptStatus status;
  final PaymentMethod method;
  final List<ReceiptLine> lines;

  /// Money off the whole bill, on top of any per-line discounts.
  final double discount;

  /// Frozen on the document at the moment of issue, so changing the rate in
  /// settings never rewrites what a customer was actually charged.
  final double taxRate;
  final String taxLabel;

  final double amountPaid;
  final String notes;
  final String cashier;

  /// Whether issuing this receipt is what took the stock off the shelf.
  final bool movesStock;

  final DateTime issuedAt;
  final DateTime? refundedAt;
  final DateTime? voidedAt;
  final String voidReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  // --- Money ---------------------------------------------------------------

  /// Every line at list price, before any discount.
  double get gross => lines.fold(0.0, (sum, l) => sum + l.gross);

  double get lineDiscount => lines.fold(0.0, (sum, l) => sum + l.discount);

  /// Line discounts plus the bill-level one, capped at the goods themselves so
  /// an over-generous discount can never make a receipt negative.
  double get discountTotal =>
      (lineDiscount + discount).clamp(0, gross <= 0 ? 0 : gross);

  /// What tax is charged on.
  double get subtotal => (gross - discountTotal).clamp(0, double.infinity);

  double get tax => subtotal * taxRate;

  double get total => subtotal + tax;

  /// Overpayment handed back at the counter.
  double get change =>
      (amountPaid - total).clamp(0, double.infinity).toDouble();

  /// Still owed. Non-zero on an account sale until it is settled.
  double get balanceDue =>
      (total - amountPaid).clamp(0, double.infinity).toDouble();

  /// Rounded to the currency's smallest sensible step, so a total of
  /// 4999.999999 from a percentage tax does not read as unpaid.
  bool get isPaid => balanceDue < 0.005;

  /// Every line after its own discount, before the bill-level one.
  double get _netOfLines => lines.fold(0.0, (sum, l) => sum + l.net);

  /// The goods handed back, valued the way they were billed: each line's
  /// share of its own discount, and then its share of the bill-level one.
  double get _refundedSubtotal {
    final goods = lines.fold(0.0, (sum, l) => sum + l.refundValue);
    if (goods <= 0 || _netOfLines <= 0) return 0;
    return goods * subtotal / _netOfLines;
  }

  /// Value handed back so far, including the tax that came off with it.
  double get refundTotal => _refundedSubtotal * (1 + taxRate);

  /// What the customer kept, before tax — the revenue margin is measured on.
  double get subtotalKept {
    if (status == ReceiptStatus.voided) return 0;
    return (subtotal - _refundedSubtotal).clamp(0, double.infinity).toDouble();
  }

  /// What the sale is worth once refunds and voids are taken off — the figure
  /// the takings on every screen are built from.
  double get netTotal => subtotalKept * (1 + taxRate);

  /// What the goods the customer kept cost, at the average banked when they
  /// left the shelf.
  double get costOfGoods {
    if (status == ReceiptStatus.voided) return 0;
    return lines.fold(0.0, (sum, l) {
      if (l.quantity <= 0) return sum;
      return sum + l.costOfGoods * l.quantityKept / l.quantity;
    });
  }

  /// Measured on the money the business keeps, so tax — which is collected on
  /// someone else's behalf — is not counted as revenue.
  double get grossProfit => subtotalKept - costOfGoods;

  /// Margin on what the customer kept, as a fraction. Null when nothing was
  /// kept, so a screen shows '—' rather than a meaningless 0%.
  double? get marginRate =>
      subtotalKept <= 0 ? null : grossProfit / subtotalKept;

  // --- Counts --------------------------------------------------------------

  int get units => lines.fold(0, (sum, l) => sum + l.quantity);
  int get unitsRefunded => lines.fold(0, (sum, l) => sum + l.quantityRefunded);
  int get unitsKept => lines.fold(0, (sum, l) => sum + l.quantityKept);

  bool get isFullyRefunded =>
      lines.isNotEmpty && lines.every((l) => l.isFullyRefunded);

  /// The most that can still come back on a line.
  int refundableOn(String lineId) {
    for (final line in lines) {
      if (line.id == lineId) return line.quantityKept;
    }
    return 0;
  }

  Receipt copyWith({
    String? customerId,
    String? customerName,
    ReceiptStatus? status,
    PaymentMethod? method,
    List<ReceiptLine>? lines,
    double? discount,
    double? amountPaid,
    String? notes,
    DateTime? refundedAt,
    DateTime? voidedAt,
    String? voidReason,
    DateTime? updatedAt,
  }) {
    return Receipt(
      id: id,
      reference: reference,
      salesOrderId: salesOrderId,
      invoiceId: invoiceId,
      customerId: customerId ?? this.customerId,
      customerName: customerName ?? this.customerName,
      status: status ?? this.status,
      method: method ?? this.method,
      lines: lines ?? this.lines,
      discount: discount ?? this.discount,
      taxRate: taxRate,
      taxLabel: taxLabel,
      amountPaid: amountPaid ?? this.amountPaid,
      notes: notes ?? this.notes,
      cashier: cashier,
      movesStock: movesStock,
      issuedAt: issuedAt,
      refundedAt: refundedAt ?? this.refundedAt,
      voidedAt: voidedAt ?? this.voidedAt,
      voidReason: voidReason ?? this.voidReason,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'reference': reference,
    'salesOrderId': salesOrderId,
    'invoiceId': invoiceId,
    'customerId': customerId,
    'customerName': customerName,
    'status': status.name,
    'method': method.name,
    'lines': [for (final l in lines) l.toJson()],
    'discount': discount,
    'taxRate': taxRate,
    'taxLabel': taxLabel,
    'amountPaid': amountPaid,
    'notes': notes,
    'cashier': cashier,
    'movesStock': movesStock,
    'issuedAt': issuedAt.toIso8601String(),
    'refundedAt': refundedAt?.toIso8601String(),
    'voidedAt': voidedAt?.toIso8601String(),
    'voidReason': voidReason,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    // Derived, but written out so an exported receipt can be read back
    // without re-deriving the arithmetic that produced the customer's total.
    'subtotal': subtotal,
    'discountTotal': discountTotal,
    'tax': tax,
    'total': total,
    'change': change,
    'balanceDue': balanceDue,
  };
}
