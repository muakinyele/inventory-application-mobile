import 'party.dart';

/// Where a sale has got to. Stock only leaves on fulfilment, so everything up
/// to [confirmed] is paperwork the stock levels never see.
enum SalesStatus { draft, confirmed, partial, fulfilled, cancelled }

SalesStatus salesStatusFrom(String? raw) => SalesStatus.values.firstWhere(
  (s) => s.name == raw,
  orElse: () => SalesStatus.draft,
);

extension SalesStatusLabel on SalesStatus {
  String get label => switch (this) {
    SalesStatus.draft => 'Draft',
    SalesStatus.confirmed => 'Confirmed',
    SalesStatus.partial => 'Part sent',
    SalesStatus.fulfilled => 'Fulfilled',
    SalesStatus.cancelled => 'Cancelled',
  };

  /// Whether stock can still be sent against it.
  bool get isOpen =>
      this == SalesStatus.confirmed || this == SalesStatus.partial;

  bool get isEditable => this == SalesStatus.draft;
}

class SalesOrderLine {
  const SalesOrderLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.quantityOrdered,
    this.quantityFulfilled = 0,
    this.unitPrice = 0,
    this.costOfGoods = 0,
  });

  final String id;
  final String itemId;

  /// Denormalised so a historical sale stays readable if the item is deleted.
  final String itemName;

  final int quantityOrdered;
  final int quantityFulfilled;
  final double unitPrice;

  /// What the stock sent so far actually cost, banked at the moment it left.
  /// Held as a total rather than a rate because the item's moving-average cost
  /// can differ between one despatch and the next.
  final double costOfGoods;

  int get outstanding =>
      (quantityOrdered - quantityFulfilled).clamp(0, quantityOrdered);

  bool get isComplete => quantityFulfilled >= quantityOrdered;

  /// What the whole line is worth if it all ships.
  double get lineTotal => quantityOrdered * unitPrice;

  /// What has actually been invoiced so far.
  double get revenue => quantityFulfilled * unitPrice;

  double get grossProfit => revenue - costOfGoods;

  SalesOrderLine copyWith({
    String? itemId,
    String? itemName,
    int? quantityOrdered,
    int? quantityFulfilled,
    double? unitPrice,
    double? costOfGoods,
  }) {
    return SalesOrderLine(
      id: id,
      itemId: itemId ?? this.itemId,
      itemName: itemName ?? this.itemName,
      quantityOrdered: quantityOrdered ?? this.quantityOrdered,
      quantityFulfilled: quantityFulfilled ?? this.quantityFulfilled,
      unitPrice: unitPrice ?? this.unitPrice,
      costOfGoods: costOfGoods ?? this.costOfGoods,
    );
  }
}

class SalesOrder {
  const SalesOrder({
    required this.id,
    required this.reference,
    this.customerId,
    this.customerName = '',
    this.priceTier = PriceTier.retailer,
    this.status = SalesStatus.draft,
    this.confirmedAt,
    this.dueAt,
    this.closedAt,
    this.notes = '',
    this.lines = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String reference;
  final String? customerId;
  final String customerName;

  /// Which of the item's two prices the lines were quoted at. Held on the
  /// document so a later change to the customer's tier never rewrites history.
  final PriceTier priceTier;

  final SalesStatus status;
  final DateTime? confirmedAt;
  final DateTime? dueAt;
  final DateTime? closedAt;
  final String notes;
  final List<SalesOrderLine> lines;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get total => lines.fold(0.0, (sum, l) => sum + l.lineTotal);
  double get revenue => lines.fold(0.0, (sum, l) => sum + l.revenue);
  double get costOfGoods => lines.fold(0.0, (sum, l) => sum + l.costOfGoods);
  double get grossProfit => revenue - costOfGoods;

  /// Margin on what has shipped, as a fraction. Null until something ships,
  /// so a screen shows '—' rather than a meaningless 0%.
  double? get marginRate => revenue <= 0 ? null : grossProfit / revenue;

  int get unitsOrdered => lines.fold(0, (sum, l) => sum + l.quantityOrdered);
  int get unitsFulfilled =>
      lines.fold(0, (sum, l) => sum + l.quantityFulfilled);
  int get unitsOutstanding => lines.fold(0, (sum, l) => sum + l.outstanding);

  bool get isFullyFulfilled =>
      lines.isNotEmpty && lines.every((l) => l.isComplete);

  /// Late once the promised date has passed with stock still to send.
  bool get isOverdue {
    final due = dueAt;
    if (due == null || !status.isOpen) return false;
    return due.isBefore(DateTime.now()) && unitsOutstanding > 0;
  }

  SalesOrder copyWith({
    String? customerId,
    String? customerName,
    PriceTier? priceTier,
    SalesStatus? status,
    DateTime? confirmedAt,
    DateTime? dueAt,
    DateTime? closedAt,
    bool clearDueAt = false,
    String? notes,
    List<SalesOrderLine>? lines,
    DateTime? updatedAt,
  }) {
    return SalesOrder(
      id: id,
      reference: reference,
      customerId: customerId ?? this.customerId,
      customerName: customerName ?? this.customerName,
      priceTier: priceTier ?? this.priceTier,
      status: status ?? this.status,
      confirmedAt: confirmedAt ?? this.confirmedAt,
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      closedAt: closedAt ?? this.closedAt,
      notes: notes ?? this.notes,
      lines: lines ?? this.lines,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'reference': reference,
    'customerId': customerId,
    'customerName': customerName,
    'priceTier': priceTier.name,
    'status': status.name,
    'confirmedAt': confirmedAt?.toIso8601String(),
    'dueAt': dueAt?.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'notes': notes,
    'lines': [
      for (final l in lines)
        {
          'id': l.id,
          'itemId': l.itemId,
          'itemName': l.itemName,
          'quantityOrdered': l.quantityOrdered,
          'quantityFulfilled': l.quantityFulfilled,
          'unitPrice': l.unitPrice,
          'costOfGoods': l.costOfGoods,
        },
    ],
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
