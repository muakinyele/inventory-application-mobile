/// Where an order has got to. Stock only moves on receipt, so everything up
/// to [ordered] is paperwork the stock levels never see.
enum PurchaseStatus { draft, ordered, partial, received, cancelled }

PurchaseStatus purchaseStatusFrom(String? raw) => PurchaseStatus.values
    .firstWhere((s) => s.name == raw, orElse: () => PurchaseStatus.draft);

extension PurchaseStatusLabel on PurchaseStatus {
  String get label => switch (this) {
    PurchaseStatus.draft => 'Draft',
    PurchaseStatus.ordered => 'Ordered',
    PurchaseStatus.partial => 'Part received',
    PurchaseStatus.received => 'Received',
    PurchaseStatus.cancelled => 'Cancelled',
  };

  /// Whether stock can still be booked in against it.
  bool get isOpen =>
      this == PurchaseStatus.ordered || this == PurchaseStatus.partial;

  bool get isEditable => this == PurchaseStatus.draft;
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.quantityOrdered,
    this.quantityReceived = 0,
    this.unitCost = 0,
  });

  final String id;
  final String itemId;

  /// Denormalised so a historical order stays readable if the item is deleted.
  final String itemName;

  final int quantityOrdered;
  final int quantityReceived;
  final double unitCost;

  int get outstanding =>
      (quantityOrdered - quantityReceived).clamp(0, quantityOrdered);

  bool get isComplete => quantityReceived >= quantityOrdered;

  double get lineTotal => quantityOrdered * unitCost;

  PurchaseOrderLine copyWith({
    String? itemId,
    String? itemName,
    int? quantityOrdered,
    int? quantityReceived,
    double? unitCost,
  }) {
    return PurchaseOrderLine(
      id: id,
      itemId: itemId ?? this.itemId,
      itemName: itemName ?? this.itemName,
      quantityOrdered: quantityOrdered ?? this.quantityOrdered,
      quantityReceived: quantityReceived ?? this.quantityReceived,
      unitCost: unitCost ?? this.unitCost,
    );
  }
}

class PurchaseOrder {
  const PurchaseOrder({
    required this.id,
    required this.reference,
    this.supplierId,
    this.supplierName = '',
    this.status = PurchaseStatus.draft,
    this.orderedAt,
    this.expectedAt,
    this.closedAt,
    this.notes = '',
    this.lines = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String reference;
  final String? supplierId;
  final String supplierName;
  final PurchaseStatus status;
  final DateTime? orderedAt;
  final DateTime? expectedAt;
  final DateTime? closedAt;
  final String notes;
  final List<PurchaseOrderLine> lines;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get total => lines.fold(0.0, (sum, l) => sum + l.lineTotal);
  int get unitsOrdered => lines.fold(0, (sum, l) => sum + l.quantityOrdered);
  int get unitsReceived => lines.fold(0, (sum, l) => sum + l.quantityReceived);
  int get unitsOutstanding => lines.fold(0, (sum, l) => sum + l.outstanding);

  bool get isFullyReceived =>
      lines.isNotEmpty && lines.every((l) => l.isComplete);

  /// Overdue once the expected date has passed with stock still outstanding.
  bool get isOverdue {
    final expected = expectedAt;
    if (expected == null || !status.isOpen) return false;
    return expected.isBefore(DateTime.now()) && unitsOutstanding > 0;
  }

  PurchaseOrder copyWith({
    String? supplierId,
    String? supplierName,
    PurchaseStatus? status,
    DateTime? orderedAt,
    DateTime? expectedAt,
    DateTime? closedAt,
    bool clearExpectedAt = false,
    String? notes,
    List<PurchaseOrderLine>? lines,
    DateTime? updatedAt,
  }) {
    return PurchaseOrder(
      id: id,
      reference: reference,
      supplierId: supplierId ?? this.supplierId,
      supplierName: supplierName ?? this.supplierName,
      status: status ?? this.status,
      orderedAt: orderedAt ?? this.orderedAt,
      expectedAt: clearExpectedAt ? null : (expectedAt ?? this.expectedAt),
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
    'supplierId': supplierId,
    'supplierName': supplierName,
    'status': status.name,
    'orderedAt': orderedAt?.toIso8601String(),
    'expectedAt': expectedAt?.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'notes': notes,
    'lines': [
      for (final l in lines)
        {
          'id': l.id,
          'itemId': l.itemId,
          'itemName': l.itemName,
          'quantityOrdered': l.quantityOrdered,
          'quantityReceived': l.quantityReceived,
          'unitCost': l.unitCost,
        },
    ],
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
