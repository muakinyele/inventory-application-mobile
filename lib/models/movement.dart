enum MovementKind { stockIn, stockOut, adjust, create, edit, delete, transfer }

const _kindNames = {
  MovementKind.stockIn: 'in',
  MovementKind.stockOut: 'out',
  MovementKind.adjust: 'adjust',
  MovementKind.create: 'create',
  MovementKind.edit: 'edit',
  MovementKind.delete: 'delete',
  MovementKind.transfer: 'transfer',
};

class Movement {
  const Movement({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.kind,
    required this.before,
    required this.after,
    this.note = '',
    this.actor = '',
    this.documentId,
    required this.at,
  });

  final String id;
  final String itemId;

  /// Denormalised so history stays readable after the item is deleted.
  final String itemName;

  final MovementKind kind;
  final int before;
  final int after;
  final String note;

  /// Who recorded it. Blank on rows written before the app had users.
  final String actor;

  /// Set when the movement came from a document — a receipt, a sale, a
  /// transfer — rather than a manual adjustment.
  final String? documentId;
  final DateTime at;

  int get delta => after - before;

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'itemName': itemName,
    'kind': _kindNames[kind],
    'before': before,
    'after': after,
    'note': note,
    'actor': actor,
    'documentId': documentId,
    'at': at.toIso8601String(),
  };

  factory Movement.fromJson(Map<String, dynamic> json) {
    final rawKind = json['kind'];
    final kind = _kindNames.entries
        .firstWhere(
          (e) => e.value == rawKind,
          orElse: () => const MapEntry(MovementKind.edit, 'edit'),
        )
        .key;
    return Movement(
      id: json['id'] is String ? json['id'] as String : '',
      itemId: json['itemId'] is String ? json['itemId'] as String : '',
      itemName: json['itemName'] is String ? json['itemName'] as String : '',
      kind: kind,
      before: json['before'] is num ? (json['before'] as num).round() : 0,
      after: json['after'] is num ? (json['after'] as num).round() : 0,
      note: json['note'] is String ? json['note'] as String : '',
      actor: json['actor'] is String ? json['actor'] as String : '',
      documentId: json['documentId'] is String
          ? json['documentId'] as String
          : null,
      at:
          (json['at'] is String
              ? DateTime.tryParse(json['at'] as String)
              : null) ??
          DateTime.now(),
    );
  }
}
