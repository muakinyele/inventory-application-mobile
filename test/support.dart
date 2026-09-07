import 'package:drift/native.dart';
import 'package:stockpile/data/database.dart';
import 'package:stockpile/data/inventory_repository.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/state/inventory_controller.dart';

/// A controller backed by a real, empty, in-memory SQLite database — the same
/// engine and schema the app uses, without touching the filesystem.
Future<InventoryController> newController({bool seeded = false}) async {
  final repo = InventoryRepository(AppDatabase(NativeDatabase.memory()));
  if (seeded) await repo.seedForTest();
  final snapshot = await repo.load();
  return InventoryController(repo, snapshot);
}

/// A repository over an empty in-memory database, for testing persistence.
InventoryRepository newRepository() =>
    InventoryRepository(AppDatabase(NativeDatabase.memory()));

/// A controller over a repository the test already holds, so it can read the
/// database back afterwards.
Future<InventoryController> controllerOver(InventoryRepository repo) async =>
    InventoryController(repo, await repo.load());

Item draft({
  String name = 'Bolt',
  int quantity = 10,
  int reorderLevel = 0,
  double unitCost = 2,
  double retailerPrice = 0,
  double distributorPrice = 0,
  String category = 'Parts',
  String barcode = '',
  String sku = '',
}) {
  final now = DateTime.now();
  return Item(
    id: '',
    name: name,
    sku: sku,
    barcode: barcode,
    category: category,
    quantity: quantity,
    reorderLevel: reorderLevel,
    unitCost: unitCost,
    retailerPrice: retailerPrice,
    distributorPrice: distributorPrice,
    createdAt: now,
    updatedAt: now,
  );
}

/// The controller persists without awaiting, so tests need a moment for those
/// futures to settle before reading the database back.
Future<void> pumpWrites() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
