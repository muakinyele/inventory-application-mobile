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
      final item = c.createItem(draft(quantity: 3));

      c.adjustStock(item.id, -10, note: 'Big pick');

      expect(c.byId(item.id)!.quantity, 0);
      expect(c.movements.first.before, 3);
      expect(c.movements.first.after, 0);
      expect(c.movements.first.delta, -3);
    });

    test('records the movement with the note and the new balance', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 10));

      c.adjustStock(item.id, 40, note: 'PO-2310');

      expect(c.byId(item.id)!.quantity, 50);
      final movement = c.movements.first;
      expect(movement.kind, MovementKind.stockIn);
      expect(movement.delta, 40);
      expect(movement.note, 'PO-2310');
    });

    test('is a no-op when already empty, leaving no movement behind', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 0));
      final before = c.movements.length;

      c.adjustStock(item.id, -5);

      expect(c.movements.length, before);
    });
  });

  test('setStock records a stocktake against the previous balance', () async {
    final c = await newController();
    final item = c.createItem(draft(quantity: 10));

    c.setStock(item.id, 7);

    expect(c.byId(item.id)!.quantity, 7);
    expect(c.movements.first.kind, MovementKind.adjust);
    expect(c.movements.first.delta, -3);
  });

  test('deleting an item keeps its history', () async {
    final c = await newController();
    final item = c.createItem(draft(name: 'Nut'));

    c.deleteItem(item.id);

    expect(c.byId(item.id), isNull);
    expect(c.movements.any((m) => m.itemName == 'Nut'), isTrue);
  });

  test(
    'editing without touching quantity logs an edit, not an adjustment',
    () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 10));

      c.updateItem(item.id, item.copyWith(name: 'Bolt M8'));

      expect(c.movements.first.kind, MovementKind.edit);
      expect(c.movements.first.delta, 0);
    },
  );

  test('new categories are folded into the pickers', () async {
    final c = await newController();

    c.createItem(draft(category: 'Fasteners'));

    expect(c.settings.categories, contains('Fasteners'));
  });

  test('lookup by code matches barcode or SKU', () async {
    final c = await newController();
    final item = c.createItem(draft(barcode: '999', sku: 'B-9'));

    expect(c.byCode('999')?.id, item.id);
    expect(c.byCode('B-9')?.id, item.id);
    expect(c.byCode('nope'), isNull);
  });

  test('needsAttention puts empty bins before merely low ones', () async {
    final c = await newController();
    c.createItem(draft(name: 'Low', quantity: 4, reorderLevel: 5));
    c.createItem(draft(name: 'Empty', quantity: 0, reorderLevel: 5));
    c.createItem(draft(name: 'Fine', quantity: 50, reorderLevel: 5));

    expect(c.needsAttention.map((i) => i.name), ['Empty', 'Low']);
  });

  test(
    'the movement log is capped so storage cannot grow without bound',
    () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 0));

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

  test('seed retailer prices sit 20% above the distributor figure', () async {
    final repo = newRepository();
    await repo.seedForTest();

    for (final item in (await repo.load()).items) {
      if (item.distributorPrice == 0) {
        expect(
          item.retailerPrice,
          0,
          reason: '${item.name} is not resold, so it has neither price',
        );
        continue;
      }
      expect(
        item.retailerPrice,
        (item.distributorPrice * 1.2).roundToDouble(),
        reason: '${item.name} should follow the same rule as the back-fill',
      );
    }
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
      c.createItem(draft(name: 'Bolt', category: 'Parts'));
      c.createItem(draft(name: 'Cable', category: 'Wiring'));

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
        final item = c.createItem(
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
      c.createItem(draft(category: 'Parts'));
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

  group('persistence', () {
    test('a created item survives a reload from the database', () async {
      final repo = newRepository();
      final first = InventoryController(repo, await repo.load());

      first.createItem(draft(name: 'Persisted', quantity: 42));
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.items.single.name, 'Persisted');
      expect(reloaded.items.single.quantity, 42);
    });

    test(
      'a deleted item is gone from the database, its movement kept',
      () async {
        final repo = newRepository();
        final controller = InventoryController(repo, await repo.load());
        final item = controller.createItem(draft(name: 'Doomed'));
        await pumpWrites();

        controller.deleteItem(item.id);
        await pumpWrites();

        final reloaded = await repo.load();
        expect(reloaded.items, isEmpty);
        expect(reloaded.movements.any((m) => m.itemName == 'Doomed'), isTrue);
      },
    );

    test('stock adjustments persist', () async {
      final repo = newRepository();
      final controller = InventoryController(repo, await repo.load());
      final item = controller.createItem(draft(quantity: 5));
      await pumpWrites();

      controller.adjustStock(item.id, 20, note: 'PO-1');
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.items.single.quantity, 25);
      expect(reloaded.movements.first.note, 'PO-1');
    });

    test('settings and category colours round-trip', () async {
      final repo = newRepository();
      final controller = InventoryController(repo, await repo.load());

      controller.updateSettings(
        controller.settings.copyWith(currency: 'NGN', companyName: 'Kola Ltd'),
      );
      controller.addCategory('Fasteners', 7);
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.settings.currency, 'NGN');
      expect(reloaded.settings.companyName, 'Kola Ltd');
      expect(reloaded.settings.categories, contains('Fasteners'));
      expect(reloaded.settings.swatchIndexFor('Fasteners'), 7);
    });

    test('erasing everything clears the tables', () async {
      final repo = newRepository();
      await repo.seedForTest();
      final controller = InventoryController(repo, await repo.load());
      expect(controller.items, isNotEmpty);

      controller.eraseAll();
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.items, isEmpty);
      expect(reloaded.movements, isEmpty);
    });

    test('the ledger is trimmed in the database, not just in memory', () async {
      final repo = newRepository();
      final controller = InventoryController(repo, await repo.load());
      final item = controller.createItem(draft(quantity: 0));
      await pumpWrites();

      for (var i = 0; i < 40; i++) {
        controller.adjustStock(item.id, 1);
      }
      await pumpWrites();
      await repo.trimMovements(10);

      final reloaded = await repo.load();
      expect(reloaded.movements.length, lessThanOrEqualTo(10));
    });
  });
}
