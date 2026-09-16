import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/csv_codec.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stock status', () {
    test('is out at zero, low at or below the level, ok above it', () {
      expect(draft(quantity: 0, reorderLevel: 5).status, StockStatus.out);
      expect(draft(quantity: 5, reorderLevel: 5).status, StockStatus.low);
      expect(draft(quantity: 6, reorderLevel: 5).status, StockStatus.ok);
    });

    test('a zero reorder level never flags a stocked item', () {
      expect(draft(quantity: 1, reorderLevel: 0).status, StockStatus.ok);
    });
  });

  group('adjustStock', () {
    test('clamps at zero rather than going negative', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 3));

      c.adjustStock(item.id, -10, note: 'Big pick');

      expect(c.byId(item.id)!.quantity, 0);
      expect(c.movements.first.before, 3);
      expect(c.movements.first.after, 0);
      expect(c.movements.first.delta, -3);
    });

    test('records the movement with the note and the new balance', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 10));

      c.adjustStock(item.id, 40, note: 'PO-2310');

      expect(c.byId(item.id)!.quantity, 50);
      final movement = c.movements.first;
      expect(movement.kind, MovementKind.stockIn);
      expect(movement.delta, 40);
      expect(movement.note, 'PO-2310');
    });

    test('is a no-op when already empty, leaving no movement behind', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 0));
      final before = c.movements.length;

      c.adjustStock(item.id, -5);

      expect(c.movements.length, before);
    });
  });

  test('setStock records a stocktake against the previous balance', () async {
    final c = await newController();
    final item = await c.createItem(draft(quantity: 10));

    c.setStock(item.id, 7);

    expect(c.byId(item.id)!.quantity, 7);
    expect(c.movements.first.kind, MovementKind.adjust);
    expect(c.movements.first.delta, -3);
  });

  test('deleting an item keeps its history', () async {
    final c = await newController();
    final item = await c.createItem(draft(name: 'Nut'));

    await c.deleteItem(item.id);

    expect(c.byId(item.id), isNull);
    expect(c.movements.any((m) => m.itemName == 'Nut'), isTrue);
  });

  test(
    'editing without touching quantity logs an edit, not an adjustment',
    () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 10));

      await c.updateItem(item.id, item.copyWith(name: 'Bolt M8'));

      expect(c.movements.first.kind, MovementKind.edit);
      expect(c.movements.first.delta, 0);
    },
  );

  test('new categories are folded into the pickers', () async {
    final c = await newController();

    await c.createItem(draft(category: 'Fasteners'));

    expect(c.settings.categories, contains('Fasteners'));
  });

  test('lookup by code matches barcode or SKU', () async {
    final c = await newController();
    final item = await c.createItem(draft(barcode: '999', sku: 'B-9'));

    expect(c.byCode('999')?.id, item.id);
    expect(c.byCode('B-9')?.id, item.id);
    expect(c.byCode('nope'), isNull);
  });

  test('needsAttention puts empty bins before merely low ones', () async {
    final c = await newController();
    await c.createItem(draft(name: 'Low', quantity: 4, reorderLevel: 5));
    await c.createItem(draft(name: 'Empty', quantity: 0, reorderLevel: 5));
    await c.createItem(draft(name: 'Fine', quantity: 50, reorderLevel: 5));

    expect(c.needsAttention.map((i) => i.name), ['Empty', 'Low']);
  });

  test(
    'the movement log is capped so storage cannot grow without bound',
    () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 0));

      for (var i = 0; i < InventoryController.maxMovements + 20; i++) {
        c.adjustStock(item.id, 1);
      }

      expect(c.movements.length, InventoryController.maxMovements);
    },
  );

  test('importDrafts adds items and learns their categories', () async {
    final c = await newController();

    final count = c.importDrafts(const [
      ItemDraft(
        name: 'Imported',
        sku: 'I-1',
        barcode: '',
        category: 'Imported Goods',
        location: '',
        quantity: 5,
        reorderLevel: 0,
        unit: 'box',
        unitCost: 1,
        retailerPrice: 3,
        distributorPrice: 2,
        supplier: '',
        notes: '',
      ),
    ]);

    expect(count, 1);
    expect(c.items.single.name, 'Imported');
    expect(c.settings.categories, contains('Imported Goods'));
    expect(c.settings.units, contains('box'));
  });

  group('categories', () {
    test('adding one registers its name and colour', () async {
      final c = await newController();

      c.addCategory('Fasteners', 3);

      expect(c.settings.categories, contains('Fasteners'));
      expect(c.settings.swatchIndexFor('Fasteners'), 3);
    });

    test('a duplicate name is ignored, case-insensitively', () async {
      final c = await newController();
      c.addCategory('Fasteners', 3);

      c.addCategory('fasteners', 5);

      expect(
        c.settings.categories.where((x) => x.toLowerCase() == 'fasteners'),
        hasLength(1),
      );
      expect(c.settings.swatchIndexFor('Fasteners'), 3);
    });

    test('renaming rewrites the items that used it', () async {
      final c = await newController();
      await c.createItem(draft(name: 'Bolt', category: 'Parts'));
      await c.createItem(draft(name: 'Cable', category: 'Wiring'));

      c.renameCategory('Parts', 'Hardware', 2);

      expect(c.items.firstWhere((i) => i.name == 'Bolt').category, 'Hardware');
      expect(c.items.firstWhere((i) => i.name == 'Cable').category, 'Wiring');
      expect(c.settings.categories, contains('Hardware'));
      expect(c.settings.categories, isNot(contains('Parts')));
    });

    test(
      'deleting clears the category but keeps the items and their stock',
      () async {
        final c = await newController();
        final item = await c.createItem(
          draft(name: 'Bolt', category: 'Parts', quantity: 9),
        );

        c.deleteCategory('Parts');

        expect(c.byId(item.id)!.category, '');
        expect(c.byId(item.id)!.quantity, 9);
        expect(c.settings.categories, isNot(contains('Parts')));
      },
    );

    test('category edits never append a movement', () async {
      final c = await newController();
      await c.createItem(draft(category: 'Parts'));
      final before = c.movements.length;

      c.renameCategory('Parts', 'Hardware', 1);
      c.deleteCategory('Hardware');

      expect(c.movements.length, before);
    });

    test('an unset category still resolves to a stable colour', () async {
      final c = await newController();

      final first = c.settings.swatchIndexFor('Never Coloured');
      final second = c.settings.swatchIndexFor('Never Coloured');

      expect(first, second);
      expect(first, inInclusiveRange(0, 11));
    });
  });

  group('persistence', () {});
}
