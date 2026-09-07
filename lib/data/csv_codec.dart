import '../models/item.dart';
import '../models/movement.dart';

const _itemColumns = [
  'name',
  'sku',
  'barcode',
  'category',
  'location',
  'quantity',
  'reorderLevel',
  'unit',
  'unitCost',
  'retailerPrice',
  'distributorPrice',
  'supplier',
  'notes',
];

String _escape(Object? value) {
  final s = value?.toString() ?? '';
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

String itemsToCsv(List<Item> items) {
  final rows = items.map((i) {
    final cells = <Object?>[
      i.name,
      i.sku,
      i.barcode,
      i.category,
      i.location,
      i.quantity,
      i.reorderLevel,
      i.unit,
      i.unitCost,
      i.retailerPrice,
      i.distributorPrice,
      i.supplier,
      i.notes,
    ];
    return cells.map(_escape).join(',');
  });
  return [_itemColumns.join(','), ...rows].join('\n');
}

String movementsToCsv(List<Movement> movements) {
  const header = ['date', 'item', 'type', 'change', 'before', 'after', 'note'];
  final rows = movements.map((m) {
    final cells = <Object?>[
      m.at.toIso8601String(),
      m.itemName,
      m.kind.name,
      m.delta,
      m.before,
      m.after,
      m.note,
    ];
    return cells.map(_escape).join(',');
  });
  return [header.join(','), ...rows].join('\n');
}

/// Minimal RFC-4180 parser: quoted cells, escaped quotes and CRLF line ends.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];

    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }

    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      // Swallow the LF of a CRLF pair.
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }

  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }

  return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
}

class ItemDraft {
  const ItemDraft({
    required this.name,
    required this.sku,
    required this.barcode,
    required this.category,
    required this.location,
    required this.quantity,
    required this.reorderLevel,
    required this.unit,
    required this.unitCost,
    required this.retailerPrice,
    required this.distributorPrice,
    required this.supplier,
    required this.notes,
  });

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

class ImportResult {
  const ImportResult(this.items, this.errors);
  final List<ItemDraft> items;
  final List<String> errors;
}

/// Maps a sheet to drafts by header name. Unknown columns are ignored and
/// missing ones fall back to defaults, so a hand-made sheet still imports.
ImportResult csvToItems(String text) {
  final rows = parseCsv(text);
  if (rows.length < 2) {
    return const ImportResult([], ['The file has no data rows.']);
  }

  final header = rows.first
      .map((h) => h.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), ''))
      .toList();
  int col(String name) => header.indexOf(name);

  final iName = col('name');
  if (iName == -1) {
    return const ImportResult([], [
      'No "name" column found. That column is required.',
    ]);
  }

  final iSku = col('sku');
  final iBarcode = col('barcode');
  final iCategory = col('category');
  final iLocation = col('location');
  final iQuantity = col('quantity');
  final iReorder = col('reorderlevel');
  final iUnit = col('unit');
  final iCost = col('unitcost');
  final iRetailer = col('retailerprice');
  // A sheet exported before the split had one "unitPrice" (or a hand-written
  // "salePrice"); either is read as the distributor figure.
  final iDistributor = [
    col('distributorprice'),
    col('unitprice'),
    col('saleprice'),
  ].firstWhere((i) => i != -1, orElse: () => -1);
  final iSupplier = col('supplier');
  final iNotes = col('notes');

  String cell(List<String> row, int i) =>
      (i == -1 || i >= row.length) ? '' : row[i].trim();

  double num_(List<String> row, int i) {
    final raw = cell(row, i).replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(raw) ?? 0;
  }

  final items = <ItemDraft>[];
  final errors = <String>[];

  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final name = cell(row, iName);
    if (name.isEmpty) {
      errors.add('Row ${r + 1}: skipped, no name.');
      continue;
    }
    final unit = cell(row, iUnit);
    items.add(
      ItemDraft(
        name: name,
        sku: cell(row, iSku),
        barcode: cell(row, iBarcode),
        category: cell(row, iCategory),
        location: cell(row, iLocation),
        quantity: num_(row, iQuantity).round(),
        reorderLevel: num_(row, iReorder).round(),
        unit: unit.isEmpty ? 'pcs' : unit,
        unitCost: num_(row, iCost),
        retailerPrice: num_(row, iRetailer),
        distributorPrice: num_(row, iDistributor),
        supplier: cell(row, iSupplier),
        notes: cell(row, iNotes),
      ),
    );
  }

  return ImportResult(items, errors);
}
