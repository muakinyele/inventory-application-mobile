import 'dart:convert';
import 'dart:typed_data';

import 'party.dart';

/// Derived stock state used for badges, filters and reorder alerts.
enum StockStatus { out, low, ok }

class Item {
  const Item({
    required this.id,
    required this.name,
    this.sku = '',
    this.barcode = '',
    this.category = '',
    this.location = '',
    this.quantity = 0,
    this.reorderLevel = 0,
    this.unit = 'pcs',
    this.unitCost = 0,
    this.retailerPrice = 0,
    this.distributorPrice = 0,
    this.supplier = '',
    this.supplierId,
    this.unitsPerPack = 1,
    this.notes = '',
    this.photo,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String sku;
  final String barcode;
  final String category;
  final String location;
  final int quantity;
  final int reorderLevel;
  final String unit;
  final double unitCost;

  /// What the goods sell for to a retailer — the higher of the two.
  final double retailerPrice;

  /// What they sell for to a distributor, who buys in volume.
  final double distributorPrice;

  /// Free-text supplier name, kept for items imported from a sheet with no
  /// matching supplier record.
  final String supplier;

  /// Set once the item is linked to a [Supplier], which supersedes [supplier].
  final String? supplierId;

  /// Stock units in one purchase pack — a carton of 24, say. Stock is always
  /// counted in single units; this only affects buying.
  final int unitsPerPack;
  final String notes;

  /// Base64 PNG of a downscaled photo, or null. Kept inline so the whole
  /// database stays a single JSON blob.
  final String? photo;

  final DateTime createdAt;
  final DateTime updatedAt;

  StockStatus get status {
    if (quantity <= 0) return StockStatus.out;
    if (reorderLevel > 0 && quantity <= reorderLevel) return StockStatus.low;
    return StockStatus.ok;
  }

  double get stockValue => quantity * unitCost;

  /// The price this item sells at for a given customer tier. Falls back to the
  /// other tier when one has never been filled in, so a sale is never quoted
  /// at zero just because only one price was entered.
  double priceFor(PriceTier tier) {
    final preferred = switch (tier) {
      PriceTier.retailer => retailerPrice,
      PriceTier.distributor => distributorPrice,
    };
    if (preferred > 0) return preferred;
    return switch (tier) {
      PriceTier.retailer => distributorPrice,
      PriceTier.distributor => retailerPrice,
    };
  }

  double get retailValue => quantity * retailerPrice;
  double get distributorValue => quantity * distributorPrice;

  Uint8List? get photoBytes {
    final data = photo;
    if (data == null) return null;
    try {
      return base64Decode(data);
    } on FormatException {
      return null;
    }
  }

  Item copyWith({
    String? name,
    String? sku,
    String? barcode,
    String? category,
    String? location,
    int? quantity,
    int? reorderLevel,
    String? unit,
    double? unitCost,
    double? retailerPrice,
    double? distributorPrice,
    String? supplier,
    String? supplierId,
    bool clearSupplierId = false,
    int? unitsPerPack,
    String? notes,
    String? photo,
    bool clearPhoto = false,
    DateTime? updatedAt,
  }) {
    return Item(
      id: id,
      name: name ?? this.name,
      sku: sku ?? this.sku,
      barcode: barcode ?? this.barcode,
      category: category ?? this.category,
      location: location ?? this.location,
      quantity: quantity ?? this.quantity,
      reorderLevel: reorderLevel ?? this.reorderLevel,
      unit: unit ?? this.unit,
      unitCost: unitCost ?? this.unitCost,
      retailerPrice: retailerPrice ?? this.retailerPrice,
      distributorPrice: distributorPrice ?? this.distributorPrice,
      supplier: supplier ?? this.supplier,
      supplierId: clearSupplierId ? null : (supplierId ?? this.supplierId),
      unitsPerPack: unitsPerPack ?? this.unitsPerPack,
      notes: notes ?? this.notes,
      photo: clearPhoto ? null : (photo ?? this.photo),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sku': sku,
    'barcode': barcode,
    'category': category,
    'location': location,
    'quantity': quantity,
    'reorderLevel': reorderLevel,
    'unit': unit,
    'unitCost': unitCost,
    'retailerPrice': retailerPrice,
    'distributorPrice': distributorPrice,
    'supplier': supplier,
    'supplierId': supplierId,
    'unitsPerPack': unitsPerPack,
    'notes': notes,
    'photo': photo,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// Tolerant of missing or wrongly-typed fields — a half-written record
  /// should degrade to defaults rather than blank the catalogue.
  factory Item.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return Item(
      id: _str(json['id']),
      name: _str(json['name']),
      sku: _str(json['sku']),
      barcode: _str(json['barcode']),
      category: _str(json['category']),
      location: _str(json['location']),
      quantity: _int(json['quantity']),
      reorderLevel: _int(json['reorderLevel']),
      unit: _str(json['unit'], fallback: 'pcs'),
      unitCost: _double(json['unitCost']),
      retailerPrice: _double(json['retailerPrice']),
      // Backups written before the split carried a single 'unitPrice', which
      // was the distributor figure.
      distributorPrice: _double(json['distributorPrice'] ?? json['unitPrice']),
      supplier: _str(json['supplier']),
      supplierId: json['supplierId'] is String
          ? json['supplierId'] as String
          : null,
      unitsPerPack: json['unitsPerPack'] is num
          ? (json['unitsPerPack'] as num).round().clamp(1, 1 << 30)
          : 1,
      notes: _str(json['notes']),
      photo: json['photo'] is String ? json['photo'] as String : null,
      createdAt: _date(json['createdAt']) ?? now,
      updatedAt: _date(json['updatedAt']) ?? now,
    );
  }
}

String _str(Object? value, {String fallback = ''}) {
  if (value is String && value.isNotEmpty) return value;
  return fallback;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
