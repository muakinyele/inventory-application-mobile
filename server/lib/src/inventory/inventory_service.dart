import 'package:drift/drift.dart';

import '../auth/tokens.dart';
import '../db/database.dart';
import '../http/api_error.dart';

/// The id to write for a row, given what the caller sent.
///
/// A blank id means "mint one". The editors build a draft with `id: ''` for
/// anything new and `toJson` always includes the key, so the field arrives
/// *present and empty* — and `Value('')` is indistinguishable from a real id
/// unless you look at the string. Treating it as one gave every new row the
/// same id, so the first save worked and the second collided on the primary
/// key: "cannot add more than one".
///
/// The document lines hit this first and were fixed there; the headers and the
/// catalogue rows had the same shape and were not.
String idOrNew(Value<String> id) =>
    id.present && id.value.isNotEmpty ? id.value : newId();

/// Reads and writes the shared inventory.
///
/// The rule this file exists to enforce: a quantity never changes without a
/// [Movements] row explaining it, and the two are written in one transaction.
/// On device that mattered less — one user, one database. Shared, an item
/// whose total disagrees with its history is a stock record nobody can trust,
/// and there is no way to reconstruct which of the two is right.
class InventoryService {
  InventoryService(this.db);

  final AuthDatabase db;

  /// Stock with no location recorded still has to be countable, so it sits in
  /// a named bin rather than a blank one.
  static const unassigned = 'Unassigned';

  // ------------------------------------------------------------------
  // Items
  // ------------------------------------------------------------------

  Future<({List<Item> items, int total})> listItems({
    String? search,
    String? category,
    String? location,
    String? supplierId,
    bool lowStockOnly = false,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = db.select(db.items);

    if (search != null && search.trim().isNotEmpty) {
      final needle = '%${search.trim().toLowerCase()}%';
      query.where(
        (t) =>
            t.name.lower().like(needle) |
            t.sku.lower().like(needle) |
            t.barcode.lower().like(needle),
      );
    }
    if (category != null && category.isNotEmpty) {
      query.where((t) => t.category.equals(category));
    }
    if (location != null && location.isNotEmpty) {
      query.where((t) => t.location.equals(location));
    }
    if (supplierId != null && supplierId.isNotEmpty) {
      query.where((t) => t.supplierId.equals(supplierId));
    }
    if (lowStockOnly) {
      // Strictly at or below, matching the client's own definition of "low"
      // so the two never disagree about which items are on the alerts screen.
      query.where((t) => t.quantity.isSmallerOrEqual(t.reorderLevel));
    }

    final total = await _countMatching(
      search: search,
      category: category,
      location: location,
      supplierId: supplierId,
      lowStockOnly: lowStockOnly,
    );

    query
      ..orderBy([(t) => OrderingTerm(expression: t.name)])
      ..limit(limit, offset: offset);

    return (items: await query.get(), total: total);
  }

  Future<int> _countMatching({
    String? search,
    String? category,
    String? location,
    String? supplierId,
    bool lowStockOnly = false,
  }) async {
    final count = db.items.id.count();
    final query = db.selectOnly(db.items)..addColumns([count]);

    if (search != null && search.trim().isNotEmpty) {
      final needle = '%${search.trim().toLowerCase()}%';
      query.where(
        db.items.name.lower().like(needle) |
            db.items.sku.lower().like(needle) |
            db.items.barcode.lower().like(needle),
      );
    }
    if (category != null && category.isNotEmpty) {
      query.where(db.items.category.equals(category));
    }
    if (location != null && location.isNotEmpty) {
      query.where(db.items.location.equals(location));
    }
    if (supplierId != null && supplierId.isNotEmpty) {
      query.where(db.items.supplierId.equals(supplierId));
    }
    if (lowStockOnly) {
      query.where(db.items.quantity.isSmallerOrEqual(db.items.reorderLevel));
    }

    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<Item> requireItem(String id) async {
    final item = await (db.select(
      db.items,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (item == null) throw ApiError.notFound;
    return item;
  }

  Future<Item> createItem(ItemsCompanion values) async {
    final now = DateTime.now().toUtc();
    final id = idOrNew(values.id);
    final companion = values.copyWith(
      id: Value(id),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    await db.into(db.items).insert(companion);

    // A new item's opening quantity is stock arriving, so it gets a movement
    // like any other change rather than appearing from nowhere.
    final opening = values.quantity.present ? values.quantity.value : 0;
    if (opening != 0) {
      final location =
          values.location.present && values.location.value.isNotEmpty
          ? values.location.value
          : unassigned;
      await _writeStockLevel(id, location, opening);
    }
    return requireItem(id);
  }

  /// Last write wins, deliberately.
  ///
  /// Two people editing an item's name or price is not worth a conflict
  /// dialogue — the fields are independent and the loser simply re-types.
  /// Quantities are the exception and do not go through here: see
  /// [adjustStock], which refuses a write made against a count that has moved.
  Future<Item> updateItem(String id, ItemsCompanion values) async {
    await requireItem(id);
    await (db.update(db.items)..where((t) => t.id.equals(id))).write(
      values.copyWith(
        id: const Value.absent(),
        // Never through this path, whatever the caller sent.
        quantity: const Value.absent(),
        createdAt: const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return requireItem(id);
  }

  Future<void> deleteItem(String id) async {
    await requireItem(id);
    await db.transaction(() async {
      await (db.delete(db.stockLevels)..where((t) => t.itemId.equals(id))).go();
      await (db.delete(db.items)..where((t) => t.id.equals(id))).go();
      // Movements are deliberately left. They carry item_name, so the history
      // stays readable, and deleting them would erase the record of stock that
      // genuinely moved.
    });
  }

  // ------------------------------------------------------------------
  // Stock
  // ------------------------------------------------------------------

  /// Moves an item's count and records why, in one transaction.
  ///
  /// [expectedQuantity] is the count the caller believed was current. When it
  /// no longer matches, the write is refused rather than applied: silently
  /// overwriting somebody else's count is exactly how a stock record stops
  /// matching the shelf, and it is invisible afterwards.
  Future<({Item item, Movement movement})> adjustStock({
    required String itemId,
    required int delta,
    required String kind,
    required String actorId,
    int? expectedQuantity,
    String location = unassigned,
    String note = '',
    String? documentId,
  }) async {
    return db.transaction(() async {
      final item = await requireItem(itemId);

      if (expectedQuantity != null && expectedQuantity != item.quantity) {
        throw ApiError(
          409,
          'stock_conflict',
          'This item now reads ${item.quantity}, not $expectedQuantity. '
              'Someone else changed it while you were working.',
        );
      }

      final after = item.quantity + delta;
      if (after < 0) {
        throw ApiError.badRequest(
          'That would leave ${item.name} at $after. Stock cannot go negative.',
        );
      }

      final bin = location.isEmpty ? unassigned : location;
      await _writeStockLevel(itemId, bin, delta);

      final movement = MovementsCompanion.insert(
        id: newId(),
        itemId: itemId,
        itemName: item.name,
        kind: kind,
        before: item.quantity,
        after: after,
        at: DateTime.now().toUtc(),
        note: Value(note),
        actor: Value(actorId),
        documentId: Value(documentId),
      );
      await db.into(db.movements).insert(movement);

      return (
        item: await requireItem(itemId),
        movement: await _lastMovement(movement.id.value),
      );
    });
  }

  /// Moves stock between bins without changing the total.
  Future<List<Movement>> transferStock({
    required String fromLocation,
    required String toLocation,
    required List<({String itemId, int quantity})> lines,
    required String actorId,
    String reference = '',
    String note = '',
  }) async {
    if (fromLocation == toLocation) {
      throw ApiError.badRequest('A transfer needs two different locations.');
    }
    if (lines.isEmpty) {
      throw ApiError.badRequest('A transfer needs at least one line.');
    }

    return db.transaction(() async {
      final now = DateTime.now().toUtc();
      final transferId = newId();
      final movements = <Movement>[];

      await db
          .into(db.transfers)
          .insert(
            TransfersCompanion.insert(
              id: transferId,
              reference: reference.isEmpty
                  ? 'TR-${transferId.substring(0, 8)}'
                  : reference,
              fromLocation: fromLocation,
              toLocation: toLocation,
              movedAt: now,
              createdAt: now,
              notes: Value(note),
            ),
          );

      var position = 0;
      for (final line in lines) {
        final item = await requireItem(line.itemId);
        if (line.quantity <= 0) {
          throw ApiError.badRequest(
            'A transfer line must move at least one unit.',
          );
        }

        final available = await _quantityAt(line.itemId, fromLocation);
        if (available < line.quantity) {
          throw ApiError.badRequest(
            '${item.name} has $available in $fromLocation, '
            'not ${line.quantity}.',
          );
        }

        await _writeStockLevel(line.itemId, fromLocation, -line.quantity);
        await _writeStockLevel(line.itemId, toLocation, line.quantity);

        await db
            .into(db.transferLines)
            .insert(
              TransferLinesCompanion.insert(
                id: newId(),
                transferId: transferId,
                itemId: line.itemId,
                itemName: item.name,
                quantity: line.quantity,
                position: Value(position++),
              ),
            );

        // The total is unchanged, so before and after match. The row exists to
        // record that the stock moved, which a total alone cannot show.
        final movementId = newId();
        await db
            .into(db.movements)
            .insert(
              MovementsCompanion.insert(
                id: movementId,
                itemId: line.itemId,
                itemName: item.name,
                kind: 'transfer',
                before: item.quantity,
                after: item.quantity,
                at: now,
                note: Value('$fromLocation → $toLocation'),
                actor: Value(actorId),
                documentId: Value(transferId),
              ),
            );
        movements.add(await _lastMovement(movementId));
      }

      return movements;
    });
  }

  /// Adds [delta] to one bin and keeps [Items.quantity] equal to the sum.
  ///
  /// Always called inside a transaction by its callers, so a failure part-way
  /// through leaves neither table changed.
  Future<void> _writeStockLevel(
    String itemId,
    String location,
    int delta,
  ) async {
    final existing =
        await (db.select(db.stockLevels)..where(
              (t) => t.itemId.equals(itemId) & t.location.equals(location),
            ))
            .getSingleOrNull();

    final next = (existing?.quantity ?? 0) + delta;
    if (existing == null) {
      await db
          .into(db.stockLevels)
          .insert(
            StockLevelsCompanion.insert(
              itemId: itemId,
              location: location,
              quantity: Value(next),
            ),
          );
    } else {
      await (db.update(db.stockLevels)..where(
            (t) => t.itemId.equals(itemId) & t.location.equals(location),
          ))
          .write(StockLevelsCompanion(quantity: Value(next)));
    }

    // Recomputed from the bins rather than incremented separately, so the
    // total cannot drift away from the rows it is meant to summarise.
    final sum = db.stockLevels.quantity.sum();
    final row =
        await (db.selectOnly(db.stockLevels)
              ..addColumns([sum])
              ..where(db.stockLevels.itemId.equals(itemId)))
            .getSingle();

    await (db.update(db.items)..where((t) => t.id.equals(itemId))).write(
      ItemsCompanion(
        quantity: Value(row.read(sum) ?? 0),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<int> _quantityAt(String itemId, String location) async {
    final row =
        await (db.select(db.stockLevels)..where(
              (t) => t.itemId.equals(itemId) & t.location.equals(location),
            ))
            .getSingleOrNull();
    return row?.quantity ?? 0;
  }

  /// Every bin, for the initial load.
  ///
  /// One request rather than one per item: the client needs the whole picture
  /// at startup, and asking per item would be a request for every row in the
  /// catalogue before the first screen could paint.
  Future<List<StockLevel>> allStock() => db.select(db.stockLevels).get();

  Future<List<StockLevel>> stockFor(String itemId) =>
      (db.select(db.stockLevels)..where((t) => t.itemId.equals(itemId))).get();

  Future<Movement> _lastMovement(String id) async =>
      (db.select(db.movements)..where((t) => t.id.equals(id))).getSingle();

  // ------------------------------------------------------------------
  // Movements
  // ------------------------------------------------------------------

  Future<List<Movement>> movements({
    String? itemId,
    int limit = 100,
    int offset = 0,
  }) {
    final query = db.select(db.movements);
    if (itemId != null && itemId.isNotEmpty) {
      query.where((t) => t.itemId.equals(itemId));
    }
    query
      // Tie-broken on id: a transfer writes several rows inside one
      // transaction, and they share a timestamp to the microsecond.
      ..orderBy([
        (t) => OrderingTerm(expression: t.at, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);
    return query.get();
  }

  // ------------------------------------------------------------------
  // Parties
  // ------------------------------------------------------------------

  Future<List<Supplier>> suppliers({bool includeArchived = false}) {
    final query = db.select(db.suppliers);
    if (!includeArchived) query.where((t) => t.archived.equals(false));
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  Future<Supplier> upsertSupplier(SuppliersCompanion values) async {
    final now = DateTime.now().toUtc();
    final id = idOrNew(values.id);
    final existing = await (db.select(
      db.suppliers,
    )..where((t) => t.id.equals(id))).getSingleOrNull();

    if (existing == null) {
      await db
          .into(db.suppliers)
          .insert(
            values.copyWith(
              id: Value(id),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    } else {
      await (db.update(db.suppliers)..where((t) => t.id.equals(id))).write(
        values.copyWith(
          id: const Value.absent(),
          createdAt: const Value.absent(),
          updatedAt: Value(now),
        ),
      );
    }
    return (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<List<Customer>> customers({bool includeArchived = false}) {
    final query = db.select(db.customers);
    if (!includeArchived) query.where((t) => t.archived.equals(false));
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  Future<Customer> upsertCustomer(CustomersCompanion values) async {
    final now = DateTime.now().toUtc();
    final id = idOrNew(values.id);
    final existing = await (db.select(
      db.customers,
    )..where((t) => t.id.equals(id))).getSingleOrNull();

    if (existing == null) {
      await db
          .into(db.customers)
          .insert(
            values.copyWith(
              id: Value(id),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    } else {
      await (db.update(db.customers)..where((t) => t.id.equals(id))).write(
        values.copyWith(
          id: const Value.absent(),
          createdAt: const Value.absent(),
          updatedAt: Value(now),
        ),
      );
    }
    return (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
  }

  // ------------------------------------------------------------------
  // Categories, lookups, preferences
  // ------------------------------------------------------------------

  Future<List<Category>> categories() => (db.select(
    db.categories,
  )..orderBy([(t) => OrderingTerm(expression: t.position)])).get();

  Future<void> replaceCategories(List<CategoriesCompanion> values) =>
      db.transaction(() async {
        await db.delete(db.categories).go();
        await db.batch((b) => b.insertAll(db.categories, values));
      });

  Future<List<Lookup>> lookups({String? kind}) {
    final query = db.select(db.lookups);
    if (kind != null && kind.isNotEmpty) {
      query.where((t) => t.kind.equals(kind));
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.kind),
      (t) => OrderingTerm(expression: t.position),
    ]);
    return query.get();
  }

  Future<void> replaceLookups(String kind, List<LookupsCompanion> values) =>
      db.transaction(() async {
        await (db.delete(db.lookups)..where((t) => t.kind.equals(kind))).go();
        await db.batch((b) => b.insertAll(db.lookups, values));
      });

  Future<Map<String, String>> preferences() async {
    final rows = await db.select(db.preferences).get();
    return {for (final row in rows) row.key: row.value};
  }

  /// Merged, not replaced: the settings screen saves the fields it owns, and
  /// must not blank the ones another screen wrote.
  Future<void> writePreferences(Map<String, String> values) => db.batch((b) {
    for (final entry in values.entries) {
      b.insert(
        db.preferences,
        PreferencesCompanion.insert(key: entry.key, value: entry.value),
        onConflict: DoUpdate(
          (_) => PreferencesCompanion(value: Value(entry.value)),
        ),
      );
    }
  });
}
