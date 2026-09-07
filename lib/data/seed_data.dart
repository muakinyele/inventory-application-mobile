import '../models/item.dart';
import '../models/movement.dart';

DateTime _daysAgo(int n) => DateTime.now().subtract(Duration(days: n));

/// Prices are in whole Naira and are plausible mid-2026 trade figures rather
/// than researched market data — this is a demo catalogue, so it only has to
/// look right at a glance. Retailer prices sit 20% above the distributor
/// figure, the same rule the v3 migration uses to back-fill existing rows.
class _Spec {
  const _Spec(
    this.name,
    this.sku,
    this.barcode,
    this.category,
    this.location,
    this.quantity,
    this.reorderLevel,
    this.unit,
    this.unitCost,
    this.retailerPrice,
    this.distributorPrice,
    this.supplier, [
    this.notes = '',
  ]);

  final String name;
  final String sku;
  final String barcode;
  final String category;
  final String location;
  final int quantity;
  final int reorderLevel;
  final String unit;
  final double unitCost;
  final double retailerPrice;
  final double distributorPrice;
  final String supplier;
  final String notes;
}

const _specs = <_Spec>[
  _Spec(
    'USB-C Cable 2m',
    'CBL-USBC-2M',
    '8801234567890',
    'Accessories',
    'Main Warehouse',
    148,
    40,
    'pcs',
    2800,
    6600,
    5500,
    'Nexa Components',
  ),
  _Spec(
    'Wireless Mouse',
    'ACC-MSE-01',
    '8801234567906',
    'Electronics',
    'Store Front',
    12,
    15,
    'pcs',
    9500,
    19200,
    16000,
    'Nexa Components',
    'Slow mover — review pricing next quarter.',
  ),
  _Spec(
    '27" Monitor',
    'ELC-MON-27',
    '8801234567913',
    'Electronics',
    'Main Warehouse',
    6,
    4,
    'pcs',
    185000,
    294000,
    245000,
    'Vertex Displays',
  ),
  _Spec(
    'Shipping Box (M)',
    'PKG-BOX-M',
    '8801234567920',
    'Packaging',
    'Main Warehouse',
    0,
    100,
    'pack',
    450,
    0,
    0,
    'BoxHouse Ltd',
    'Reorder in packs of 250.',
  ),
  _Spec(
    'Bubble Wrap Roll',
    'PKG-BWR-50',
    '8801234567937',
    'Packaging',
    'Main Warehouse',
    23,
    10,
    'roll',
    7500,
    0,
    0,
    'BoxHouse Ltd',
  ),
  _Spec(
    'A4 Paper Ream',
    'OFF-PPR-A4',
    '8801234567944',
    'Office',
    'Store Front',
    34,
    12,
    'pack',
    8500,
    13200,
    11000,
    'Clarke Office Supply',
  ),
  _Spec(
    'Thermal Label 4x6',
    'OFF-LBL-46',
    '8801234567951',
    'Office',
    'Van 1',
    8,
    20,
    'box',
    18000,
    0,
    0,
    'Clarke Office Supply',
  ),
  _Spec(
    'Aluminium Sheet 1mm',
    'RAW-ALU-1MM',
    '8801234567968',
    'Raw Materials',
    'Main Warehouse',
    62,
    25,
    'pcs',
    22000,
    0,
    0,
    'Meridian Metals',
  ),
  _Spec(
    'Laptop Stand',
    'ACC-STD-01',
    '8801234567975',
    'Accessories',
    'Store Front',
    19,
    8,
    'pcs',
    14000,
    30000,
    25000,
    'Vertex Displays',
  ),
  _Spec(
    'Cleaning Solution 1L',
    'OFF-CLN-1L',
    '8801234567982',
    'Office',
    'Van 1',
    3,
    6,
    'litre',
    4200,
    0,
    0,
    'Clarke Office Supply',
  ),
];

/// Stable ids so the seeded movements can reference the seeded items.
String _seedId(int index) => 'seed-${index + 1}';

List<Item> seedItems() {
  return List.generate(_specs.length, (i) {
    final s = _specs[i];
    return Item(
      id: _seedId(i),
      name: s.name,
      sku: s.sku,
      barcode: s.barcode,
      category: s.category,
      location: s.location,
      quantity: s.quantity,
      reorderLevel: s.reorderLevel,
      unit: s.unit,
      unitCost: s.unitCost,
      retailerPrice: s.retailerPrice,
      distributorPrice: s.distributorPrice,
      supplier: s.supplier,
      notes: s.notes,
      createdAt: _daysAgo(60 - i),
      updatedAt: _daysAgo(i % 9),
    );
  });
}

class _Mv {
  const _Mv(this.item, this.kind, this.delta, this.after, this.note, this.days);
  final int item;
  final MovementKind kind;
  final int delta;
  final int after;
  final String note;
  final int days;
}

const _movements = <_Mv>[
  _Mv(3, MovementKind.stockOut, -60, 0, 'Bulk pick for Q3 shipments', 1),
  _Mv(1, MovementKind.stockOut, -3, 12, 'Counter sale', 1),
  _Mv(0, MovementKind.stockIn, 100, 148, 'PO-2291 received', 2),
  _Mv(9, MovementKind.stockOut, -2, 3, 'Van restock', 3),
  _Mv(6, MovementKind.stockOut, -4, 8, 'Labels for outbound batch', 4),
  _Mv(2, MovementKind.stockIn, 6, 6, 'PO-2288 received', 6),
  _Mv(8, MovementKind.stockOut, -5, 19, 'Store transfer', 7),
  _Mv(5, MovementKind.stockIn, 20, 34, 'PO-2284 received', 9),
];

List<Movement> seedMovements() {
  return List.generate(_movements.length, (i) {
    final m = _movements[i];
    return Movement(
      id: 'seed-mv-${i + 1}',
      itemId: _seedId(m.item),
      itemName: _specs[m.item].name,
      kind: m.kind,
      before: m.after - m.delta,
      after: m.after,
      note: m.note,
      at: _daysAgo(m.days),
    );
  });
}
