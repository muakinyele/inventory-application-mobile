import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:stockpile/data/database.dart';
import 'package:stockpile/data/inventory_repository.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

/// The schema exactly as v1 shipped: one `unit_price` column on `items`, and
/// everything else unchanged. Written straight to sqlite so drift genuinely
/// opens a v1 database and runs its upgrade, rather than seeing a fresh v2.
const _v1Schema = [
  '''
  CREATE TABLE "items" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "sku" TEXT NOT NULL DEFAULT '',
    "barcode" TEXT NOT NULL DEFAULT '',
    "category" TEXT NOT NULL DEFAULT '',
    "location" TEXT NOT NULL DEFAULT '',
    "quantity" INTEGER NOT NULL DEFAULT 0,
    "reorder_level" INTEGER NOT NULL DEFAULT 0,
    "unit" TEXT NOT NULL DEFAULT 'pcs',
    "unit_cost" REAL NOT NULL DEFAULT 0,
    "unit_price" REAL NOT NULL DEFAULT 0,
    "supplier" TEXT NOT NULL DEFAULT '',
    "notes" TEXT NOT NULL DEFAULT '',
    "photo" TEXT NULL,
    "created_at" TEXT NOT NULL,
    "updated_at" TEXT NOT NULL
  )''',
  '''
  CREATE TABLE "movements" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "item_id" TEXT NOT NULL,
    "item_name" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "before" INTEGER NOT NULL,
    "after" INTEGER NOT NULL,
    "note" TEXT NOT NULL DEFAULT '',
    "at" TEXT NOT NULL
  )''',
  '''
  CREATE TABLE "categories" (
    "name" TEXT NOT NULL PRIMARY KEY,
    "swatch_index" INTEGER NULL,
    "position" INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE "lookups" (
    "kind" TEXT NOT NULL,
    "value" TEXT NOT NULL,
    "position" INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY ("kind", "value")
  )''',
  '''
  CREATE TABLE "preferences" (
    "key" TEXT NOT NULL PRIMARY KEY,
    "value" TEXT NOT NULL
  )''',
];

Database _openV1() {
  final raw = sqlite3.openInMemory();
  for (final statement in _v1Schema) {
    raw.execute(statement);
  }
  raw.execute('''
    INSERT INTO "items"
      ("id", "name", "quantity", "unit_cost", "unit_price",
       "created_at", "updated_at")
    VALUES
      ('legacy-1', 'Legacy Monitor', 6, 185000, 245000,
       '2026-09-01T10:00:00.000', '2026-09-01T10:00:00.000')
  ''');
  raw.execute('''
    INSERT INTO "items"
      ("id", "name", "quantity", "unit_cost", "unit_price",
       "created_at", "updated_at")
    VALUES
      ('legacy-2', 'Packing Tape', 40, 900, 0,
       '2026-09-01T10:00:00.000', '2026-09-01T10:00:00.000')
  ''');
  raw.execute('''
    INSERT INTO "items"
      ("id", "name", "location", "quantity", "unit_cost", "unit_price",
       "created_at", "updated_at")
    VALUES
      ('legacy-3', 'Shelf Bracket', 'Warehouse', 25, 400, 700,
       '2026-09-01T10:00:00.000', '2026-09-01T10:00:00.000')
  ''');
  raw.execute('''
    INSERT INTO "movements"
      ("id", "item_id", "item_name", "kind", "before", "after", "note", "at")
    VALUES
      ('mv-1', 'legacy-1', 'Legacy Monitor', 'stockIn', 0, 6, 'PO-1',
       '2026-09-01T10:00:00.000')
  ''');
  raw.execute('PRAGMA user_version = 1');
  return raw;
}

/// The v2 schema — the split has happened but nothing has been back-filled.
Database _openV2() {
  final raw = sqlite3.openInMemory();
  for (final statement in _v1Schema) {
    raw.execute(
      statement.replaceFirst(
        '"unit_price" REAL NOT NULL DEFAULT 0',
        '"distributor_price" REAL NOT NULL DEFAULT 0,\n'
            '    "retailer_price" REAL NOT NULL DEFAULT 0',
      ),
    );
  }
  raw.execute('''
    INSERT INTO "items"
      ("id", "name", "quantity", "unit_cost",
       "distributor_price", "retailer_price", "created_at", "updated_at")
    VALUES
      ('priced', 'Hand Priced', 3, 1000, 2000, 5000,
       '2026-09-01T10:00:00.000', '2026-09-01T10:00:00.000')
  ''');
  raw.execute('PRAGMA user_version = 2');
  return raw;
}

/// The state that actually broke in the browser: the v1 -> v2 column rename
/// committed, but `user_version` never persisted, so the database still calls
/// itself v1 while carrying v2 columns.
Database _openHalfApplied() {
  final raw = _openV2();
  raw.execute('PRAGMA user_version = 1');
  return raw;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'upgrading from v1 keeps the old price as the distributor price',
    () async {
      final raw = _openV1();
      final db = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(db.close);

      final snapshot = await InventoryRepository(db).load();

      final item = snapshot.items.firstWhere((i) => i.id == 'legacy-1');
      expect(item.name, 'Legacy Monitor');
      expect(
        item.quantity,
        6,
        reason: 'existing stock must survive the upgrade',
      );
      expect(item.unitCost, 185000);
      expect(
        item.distributorPrice,
        245000,
        reason: "v1's single sale price was the distributor figure",
      );
      expect(
        item.retailerPrice,
        294000,
        reason: 'back-filled to 20% above the distributor price',
      );
    },
  );

  test('the upgrade leaves the movement ledger untouched', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    expect(snapshot.movements.single.itemName, 'Legacy Monitor');
    expect(snapshot.movements.single.after, 6);
  });

  test('an item with no distributor price is left alone', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    final tape = snapshot.items.firstWhere((i) => i.id == 'legacy-2');
    expect(tape.distributorPrice, 0);
    expect(
      tape.retailerPrice,
      0,
      reason: 'nothing to derive a retailer price from',
    );
  });

  test(
    'a retailer price already entered by hand is never overwritten',
    () async {
      final raw = _openV2();
      final db = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(db.close);

      final snapshot = await InventoryRepository(db).load();

      final item = snapshot.items.single;
      expect(item.distributorPrice, 2000);
      expect(
        item.retailerPrice,
        5000,
        reason: 'the back-fill must not clobber a deliberate figure',
      );
    },
  );

  test('a half-applied migration recovers instead of crashing', () async {
    final raw = _openHalfApplied();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // The bug this guards: drift reports from == 1 and a blind RENAME COLUMN
    // fails, because `unit_price` is already gone.
    final snapshot = await InventoryRepository(db).load();

    final item = snapshot.items.single;
    expect(item.distributorPrice, 2000);
    expect(item.retailerPrice, 5000);
    expect(
      raw.select('PRAGMA user_version').first.values.first,
      db.schemaVersion,
    );
  });

  test('an upgraded database reports the current schema version', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await InventoryRepository(db).load();

    expect(
      raw.select('PRAGMA user_version').first.values.first,
      db.schemaVersion,
    );
  });

  test('the upgrade puts existing stock in the location it was in', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    expect(
      snapshot.levels['legacy-3'],
      {'Warehouse': 25},
      reason: 'stock that already had a location keeps it',
    );
  });

  test('stock with no location upgrades into Unassigned', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    expect(snapshot.levels['legacy-1'], {'Unassigned': 6});
    expect(
      snapshot.levels['legacy-2'],
      {'Unassigned': 40},
      reason: 'no stock may be stranded by the upgrade',
    );
  });

  test('every upgraded item is balanced', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    for (final item in snapshot.items) {
      final bins = snapshot.levels[item.id] ?? const <String, int>{};
      expect(
        bins.values.fold(0, (sum, q) => sum + q),
        item.quantity,
        reason: '${item.name} must still add up after the upgrade',
      );
    }
  });

  test('an upgraded database gets a working receipt book', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);
    final repo = InventoryRepository(db);

    final controller = InventoryController(repo, await repo.load());
    // The receipt tables did not exist in v1, so this only works if the
    // upgrade created them.
    expect(controller.receipts, isEmpty);

    final receipt = await controller.issueReceipt(
      lines: [
        ReceiptLine(
          id: 'rl1',
          itemId: 'legacy-3',
          itemName: 'Shelf Bracket',
          quantity: 5,
          unitPrice: 700,
        ),
      ],
      amountPaid: 3500,
    );

    expect(receipt, isNotNull);
    await pumpWrites();

    final reloaded = await repo.load();
    expect(reloaded.receipts.single.reference, receipt!.reference);
    expect(reloaded.receipts.single.total, 3500);
    // The sale came off the legacy stock, bins and all.
    expect(reloaded.items.firstWhere((i) => i.id == 'legacy-3').quantity, 20);
    expect(reloaded.levels['legacy-3'], {'Warehouse': 20});
  });

  test('receipt settings default cleanly on an upgraded database', () async {
    final raw = _openV1();
    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final snapshot = await InventoryRepository(db).load();

    // None of these keys exist in a v1 preferences table.
    expect(snapshot.settings.taxRate, 0);
    expect(snapshot.settings.taxLabel, 'VAT');
    expect(snapshot.settings.companyAddress, '');
    expect(snapshot.settings.receiptFooter, isNotEmpty);
  });
}
