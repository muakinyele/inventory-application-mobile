/// The bin stock sits in when no location was ever recorded for it. Held as a
/// real name rather than a blank so it can be counted, filtered and moved out
/// of like any other location.
const unassignedLocation = 'Unassigned';

/// Normalises a location for storage: blank becomes [unassignedLocation].
String stockBin(String? location) {
  final trimmed = (location ?? '').trim();
  return trimmed.isEmpty ? unassignedLocation : trimmed;
}

class TransferLine {
  const TransferLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.quantity,
  });

  final String id;
  final String itemId;

  /// Denormalised so the record stays readable if the item is deleted.
  final String itemName;

  final int quantity;
}

/// A completed movement of stock between two locations.
class Transfer {
  const Transfer({
    required this.id,
    required this.reference,
    required this.fromLocation,
    required this.toLocation,
    this.notes = '',
    this.lines = const [],
    required this.movedAt,
    required this.createdAt,
  });

  final String id;
  final String reference;
  final String fromLocation;
  final String toLocation;
  final String notes;
  final List<TransferLine> lines;
  final DateTime movedAt;
  final DateTime createdAt;

  int get units => lines.fold(0, (sum, l) => sum + l.quantity);

  Map<String, dynamic> toJson() => {
    'id': id,
    'reference': reference,
    'fromLocation': fromLocation,
    'toLocation': toLocation,
    'notes': notes,
    'lines': [
      for (final l in lines)
        {
          'id': l.id,
          'itemId': l.itemId,
          'itemName': l.itemName,
          'quantity': l.quantity,
        },
    ],
    'movedAt': movedAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };
}
