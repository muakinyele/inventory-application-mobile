import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/csv_codec.dart';
import 'package:stockpile/models/item.dart';

Item _item({
  String name = 'Widget',
  String notes = '',
  String supplier = '',
  int quantity = 0,
  double unitCost = 0,
}) {
  final now = DateTime.now();
  return Item(
    id: 'x',
    name: name,
    sku: 'W-1',
    barcode: '123',
    category: 'Parts',
    location: 'A1',
    quantity: quantity,
    reorderLevel: 5,
    unit: 'pcs',
    unitCost: unitCost,
    retailerPrice: 3,
    distributorPrice: 2.5,
    supplier: supplier,
    notes: notes,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('parseCsv', () {
    test('handles escaped quotes and CRLF line ends', () {
      expect(parseCsv('a,b\r\n1,"x""y"'), [
        ['a', 'b'],
        ['1', 'x"y'],
      ]);
    });

    test('keeps newlines inside a quoted cell', () {
      expect(parseCsv('a\n"one\ntwo"'), [
        ['a'],
        ['one\ntwo'],
      ]);
    });

    test('drops entirely blank rows', () {
      expect(parseCsv('a\n\n,,\nb').length, 2);
    });
  });

  group('round trip', () {
    test('survives commas, quotes and newlines in values', () {
      final source = _item(
        name: 'Widget, large',
        supplier: 'Acme "Co"',
        notes: 'line one\nline two',
        quantity: 12,
        unitCost: 1.5,
      );

      final result = csvToItems(itemsToCsv([source]));

      expect(result.errors, isEmpty);
      final draft = result.items.single;
      expect(draft.name, 'Widget, large');
      expect(draft.supplier, 'Acme "Co"');
      expect(draft.notes, 'line one\nline two');
      expect(draft.quantity, 12);
      expect(draft.unitCost, 1.5);
    });
  });

  group('csvToItems', () {
    test('accepts header aliases, thousands separators and currency signs', () {
      const messy =
          'Name,SKU,Quantity,Unit Cost\r\nBolt,B-1,"1,200",\$0.40\r\n\r\n,,,\r\n';

      final result = csvToItems(messy);

      expect(result.items.length, 1);
      expect(result.items.single.quantity, 1200);
      expect(result.items.single.unitCost, 0.40);
    });

    test('defaults the unit and skips nameless rows', () {
      final result = csvToItems('name,quantity\nNut,\n,7\n');

      expect(result.items.single.name, 'Nut');
      expect(result.items.single.unit, 'pcs');
      expect(result.items.single.quantity, 0);
      expect(result.errors.single, contains('Row 3'));
    });

    test('carries both sales prices through a round trip', () {
      final result = csvToItems(itemsToCsv([_item(quantity: 4, unitCost: 10)]));

      expect(result.items.single.retailerPrice, 3);
      expect(result.items.single.distributorPrice, 2.5);
    });

    test('a sheet exported before the split reads as a distributor price', () {
      // Older exports carried one "unitPrice" column; a hand-written sheet
      // might say "salePrice". Both are the distributor figure.
      final legacy = csvToItems('name,unitPrice\nBolt,1200\n');
      expect(legacy.items.single.distributorPrice, 1200);
      expect(legacy.items.single.retailerPrice, 0);

      final handWritten = csvToItems('name,Sale Price\nNut,900\n');
      expect(handWritten.items.single.distributorPrice, 900);
    });

    test('rejects a sheet with no name column', () {
      final result = csvToItems('sku\nX-1');

      expect(result.items, isEmpty);
      expect(result.errors.single, contains('name'));
    });

    test('reports a file with no data rows', () {
      expect(csvToItems('name').errors.single, contains('no data rows'));
    });
  });
}
