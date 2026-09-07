import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show ThemeMode;

import '../models/app_settings.dart';
import '../models/item.dart' as model;
import '../models/movement.dart' as model;
import '../models/party.dart' as model;
import '../models/purchase_order.dart' as model;
import '../models/sales_order.dart' as model;
import '../models/transfer.dart' as model;
import 'database.dart';
import 'seed_data.dart';

/// A snapshot of the whole catalogue, read once at startup and then kept in
/// step by the controller. Reads stay synchronous for the UI; writes go
/// through to SQLite.
class Snapshot {
  const Snapshot({
    required this.items,
    required this.movements,
    this.suppliers = const [],
    this.customers = const [],
    this.purchaseOrders = const [],
    this.salesOrders = const [],
    this.transfers = const [],
    this.levels = const {},
    this.sequences = const {},
    required this.settings,
  });

  final List<model.Item> items;
  final List<model.Movement> movements;
  final List<model.Supplier> suppliers;
  final List<model.Customer> customers;
  final List<model.PurchaseOrder> purchaseOrders;
  final List<model.SalesOrder> salesOrders;
  final List<model.Transfer> transfers;

  /// Stock broken down by location, keyed item id -> location -> quantity.
  final Map<String, Map<String, int>> levels;

  /// Persistent document counters, keyed by prefix, so a reference is never
  /// reused even after the document that had it is deleted.
  final Map<String, int> sequences;
  final AppSettings settings;

  static const empty = Snapshot(
    items: [],
    movements: [],
    suppliers: [],
    customers: [],
    purchaseOrders: [],
    salesOrders: [],
    transfers: [],
    levels: {},
    settings: AppSettings(),
  );
}

/// Every read and write in the app goes through here to a real SQLite
/// database — `sqlite3` on Android, iOS and macOS, and the same engine
/// compiled to WebAssembly (backed by IndexedDB) in the browser.
class InventoryRepository {
  InventoryRepository(this.db);

  final AppDatabase db;

  static const _seededKey = 'seeded';

  static Future<InventoryRepository> open({AppDatabase? database}) async {
    final repo = InventoryRepository(database ?? AppDatabase());
    await repo._seedIfFirstRun();
    return repo;
  }

  /// The sample catalogue is written once, on a genuinely empty database, and
  /// a marker row stops it coming back after the user erases everything.
  Future<void> _seedIfFirstRun() async {
    final marker = await (db.select(
      db.preferences,
    )..where((p) => p.key.equals(_seededKey))).getSingleOrNull();
    if (marker != null) return;

    await replaceAll(
      items: seedItems(),
      movements: seedMovements(),
      settings: const AppSettings(),
    );
    await db
        .into(db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(key: _seededKey, value: '1'),
        );
  }

  /// Writes the sample catalogue. Exposed so tests can build a seeded
  /// database without going through first-run detection.
  @visibleForTesting
  Future<void> seedForTest() => replaceAll(
    items: seedItems(),
    movements: seedMovements(),
    settings: const AppSettings(),
  );

  Future<Snapshot> load() async {
    final itemRows = await (db.select(
      db.items,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    final movementRows =
        await (db.select(db.movements)..orderBy([
              (t) => OrderingTerm.desc(t.at),
              (t) => OrderingTerm.desc(t.id),
            ]))
            .get();

    final supplierRows = await (db.select(
      db.suppliers,
    )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();
    final customerRows = await (db.select(
      db.customers,
    )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

    return Snapshot(
      purchaseOrders: await _loadPurchaseOrders(),
      salesOrders: await _loadSalesOrders(),
      transfers: await _loadTransfers(),
      levels: await loadLevels(),
      sequences: await _loadSequences(),
      items: itemRows.map(_toItem).toList(),
      movements: movementRows.map(_toMovement).toList(),
      suppliers: supplierRows.map(_toSupplier).toList(),
      customers: customerRows.map(_toCustomer).toList(),
      settings: await _loadSettings(),
    );
  }

  // --- Items ---------------------------------------------------------------

  Future<void> upsertItem(model.Item item) =>
      db.into(db.items).insertOnConflictUpdate(_itemRow(item));

  Future<void> upsertItems(Iterable<model.Item> items) {
    return db.batch(
      (batch) => batch.insertAllOnConflictUpdate(
        db.items,
        items.map(_itemRow).toList(),
      ),
    );
  }

  Future<void> deleteItem(String id) =>
      (db.delete(db.items)..where((t) => t.id.equals(id))).go();

  // --- Suppliers and customers ---------------------------------------------

  Future<void> upsertSupplier(model.Supplier supplier) =>
      db.into(db.suppliers).insertOnConflictUpdate(_supplierRow(supplier));

  Future<void> deleteSupplier(String id) =>
      (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go();

  Future<void> upsertCustomer(model.Customer customer) =>
      db.into(db.customers).insertOnConflictUpdate(_customerRow(customer));

  Future<void> deleteCustomer(String id) =>
      (db.delete(db.customers)..where((t) => t.id.equals(id))).go();

  // --- Purchase orders -----------------------------------------------------

  Future<List<model.PurchaseOrder>> _loadPurchaseOrders() async {
    final orders = await (db.select(
      db.purchaseOrders,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    if (orders.isEmpty) return const [];

    final lines = await (db.select(
      db.purchaseOrderLines,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

    final byOrder = <String, List<model.PurchaseOrderLine>>{};
    for (final line in lines) {
      byOrder.putIfAbsent(line.orderId, () => []).add(_toLine(line));
    }
    return [
      for (final order in orders)
        _toOrder(order, byOrder[order.id] ?? const []),
    ];
  }

  /// Writes the order and replaces its lines in one transaction, so a saved
  /// order is never left with a stale mix of old and new lines.
  Future<void> savePurchaseOrder(model.PurchaseOrder order) =>
      db.transaction(() => _writePurchaseOrder(order));

  Future<void> _writePurchaseOrder(model.PurchaseOrder order) async {
    await db.into(db.purchaseOrders).insertOnConflictUpdate(_orderRow(order));
    await (db.delete(
      db.purchaseOrderLines,
    )..where((t) => t.orderId.equals(order.id))).go();
    if (order.lines.isEmpty) return;
    await db.batch(
      (batch) => batch.insertAll(db.purchaseOrderLines, [
        for (final (index, line) in order.lines.indexed)
          _lineRow(order.id, line, index),
      ]),
    );
  }

  Future<void> deletePurchaseOrder(String id) async {
    await db.transaction(() async {
      await (db.delete(
        db.purchaseOrderLines,
      )..where((t) => t.orderId.equals(id))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(id))).go();
    });
  }

  // --- Sales orders --------------------------------------------------------

  Future<List<model.SalesOrder>> _loadSalesOrders() async {
    final orders = await (db.select(
      db.salesOrders,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    if (orders.isEmpty) return const [];

    final lines = await (db.select(
      db.salesOrderLines,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

    final byOrder = <String, List<model.SalesOrderLine>>{};
    for (final line in lines) {
      byOrder.putIfAbsent(line.orderId, () => []).add(_toSalesLine(line));
    }
    return [
      for (final order in orders)
        _toSalesOrder(order, byOrder[order.id] ?? const []),
    ];
  }

  Future<void> saveSalesOrder(model.SalesOrder order) =>
      db.transaction(() => _writeSalesOrder(order));

  Future<void> _writeSalesOrder(model.SalesOrder order) async {
    await db.into(db.salesOrders).insertOnConflictUpdate(_salesOrderRow(order));
    await (db.delete(
      db.salesOrderLines,
    )..where((t) => t.orderId.equals(order.id))).go();
    if (order.lines.isEmpty) return;
    await db.batch(
      (batch) => batch.insertAll(db.salesOrderLines, [
        for (final (index, line) in order.lines.indexed)
          _salesLineRow(order.id, line, index),
      ]),
    );
  }

  Future<void> deleteSalesOrder(String id) async {
    await db.transaction(() async {
      await (db.delete(
        db.salesOrderLines,
      )..where((t) => t.orderId.equals(id))).go();
      await (db.delete(db.salesOrders)..where((t) => t.id.equals(id))).go();
    });
  }

  // --- Stock by location ---------------------------------------------------

  Future<Map<String, Map<String, int>>> loadLevels() async {
    final rows = await db.select(db.stockLevels).get();
    final byItem = <String, Map<String, int>>{};
    for (final row in rows) {
      byItem.putIfAbsent(row.itemId, () => {})[row.location] = row.quantity;
    }
    return byItem;
  }

  /// Replaces one item's whole breakdown. Empty bins are dropped rather than
  /// stored as zeroes, so a location an item has left does not linger.
  Future<void> saveLevels(String itemId, Map<String, int> levels) =>
      db.transaction(() => _writeLevels(itemId, levels));

  Future<void> _writeLevels(String itemId, Map<String, int> levels) async {
    await (db.delete(
      db.stockLevels,
    )..where((t) => t.itemId.equals(itemId))).go();
    final rows = [
      for (final entry in levels.entries)
        if (entry.value != 0)
          StockLevelsCompanion.insert(
            itemId: itemId,
            location: entry.key,
            quantity: Value(entry.value),
          ),
    ];
    if (rows.isEmpty) return;
    await db.batch((batch) => batch.insertAll(db.stockLevels, rows));
  }

  Future<void> saveAllLevels(Map<String, Map<String, int>> levels) async {
    await db.transaction(() async {
      await db.delete(db.stockLevels).go();
      final rows = [
        for (final item in levels.entries)
          for (final bin in item.value.entries)
            if (bin.value != 0)
              StockLevelsCompanion.insert(
                itemId: item.key,
                location: bin.key,
                quantity: Value(bin.value),
              ),
      ];
      if (rows.isEmpty) return;
      await db.batch((batch) => batch.insertAll(db.stockLevels, rows));
    });
  }

  Future<void> deleteLevels(String itemId) =>
      (db.delete(db.stockLevels)..where((t) => t.itemId.equals(itemId))).go();

  // --- Transfers -----------------------------------------------------------

  Future<List<model.Transfer>> _loadTransfers() async {
    final rows = await (db.select(
      db.transfers,
    )..orderBy([(t) => OrderingTerm.desc(t.movedAt)])).get();
    if (rows.isEmpty) return const [];

    final lines = await (db.select(
      db.transferLines,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

    final byTransfer = <String, List<model.TransferLine>>{};
    for (final line in lines) {
      byTransfer
          .putIfAbsent(line.transferId, () => [])
          .add(
            model.TransferLine(
              id: line.id,
              itemId: line.itemId,
              itemName: line.itemName,
              quantity: line.quantity,
            ),
          );
    }
    return [
      for (final row in rows)
        model.Transfer(
          id: row.id,
          reference: row.reference,
          fromLocation: row.fromLocation,
          toLocation: row.toLocation,
          notes: row.notes,
          lines: byTransfer[row.id] ?? const [],
          movedAt: row.movedAt,
          createdAt: row.createdAt,
        ),
    ];
  }

  Future<void> saveTransfer(model.Transfer transfer) =>
      db.transaction(() => _writeTransfer(transfer));

  Future<void> _writeTransfer(model.Transfer transfer) async {
    await db
        .into(db.transfers)
        .insertOnConflictUpdate(
          TransfersCompanion.insert(
            id: transfer.id,
            reference: transfer.reference,
            fromLocation: transfer.fromLocation,
            toLocation: transfer.toLocation,
            notes: Value(transfer.notes),
            movedAt: transfer.movedAt,
            createdAt: transfer.createdAt,
          ),
        );
    await (db.delete(
      db.transferLines,
    )..where((t) => t.transferId.equals(transfer.id))).go();
    if (transfer.lines.isEmpty) return;
    await db.batch(
      (batch) => batch.insertAll(db.transferLines, [
        for (final (index, line) in transfer.lines.indexed)
          TransferLinesCompanion.insert(
            id: line.id,
            transferId: transfer.id,
            itemId: line.itemId,
            itemName: line.itemName,
            quantity: line.quantity,
            position: Value(index),
          ),
      ]),
    );
  }

  // --- Atomic stock changes ------------------------------------------------

  /// Commits everything one stock document does, in a single transaction.
  ///
  /// Stock levels, the ledger rows that explain them and the document itself
  /// land together or not at all. Written as one unit because the alternative
  /// has a real failure mode: a partial write leaves stock moved with nothing
  /// in the ledger to account for it, which is the one inconsistency an
  /// inventory system must never produce.
  Future<void> commitStockChange({
    List<model.Item> items = const [],
    Map<String, Map<String, int>> levels = const {},
    List<model.Movement> movements = const [],
    model.PurchaseOrder? purchaseOrder,
    model.SalesOrder? salesOrder,
    model.Transfer? transfer,
  }) async {
    await db.transaction(() async {
      if (items.isNotEmpty) await upsertItems(items);
      for (final entry in levels.entries) {
        await _writeLevels(entry.key, entry.value);
      }
      if (movements.isNotEmpty) await insertMovements(movements);
      if (purchaseOrder != null) await _writePurchaseOrder(purchaseOrder);
      if (salesOrder != null) await _writeSalesOrder(salesOrder);
      if (transfer != null) await _writeTransfer(transfer);
    });
  }

  // --- Document sequences --------------------------------------------------

  static const _sequencePrefix = 'sequence.';

  Future<Map<String, int>> _loadSequences() async {
    final rows = await (db.select(
      db.preferences,
    )..where((p) => p.key.like('$_sequencePrefix%'))).get();
    return {
      for (final row in rows)
        row.key.substring(_sequencePrefix.length): int.tryParse(row.value) ?? 0,
    };
  }

  Future<void> saveSequence(String key, int value) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          key: '$_sequencePrefix$key',
          value: '$value',
        ),
      );

  // --- Movements -----------------------------------------------------------

  Future<void> insertMovement(model.Movement movement) =>
      db.into(db.movements).insertOnConflictUpdate(_movementRow(movement));

  Future<void> insertMovements(Iterable<model.Movement> movements) {
    return db.batch(
      (batch) => batch.insertAllOnConflictUpdate(
        db.movements,
        movements.map(_movementRow).toList(),
      ),
    );
  }

  /// Keeps the ledger bounded to the newest [keep] rows.
  ///
  /// Selects the survivors by rank and deletes the rest, rather than comparing
  /// timestamps — rows recorded in the same instant would otherwise all sit on
  /// the wrong side of a cutoff.
  Future<void> trimMovements(int keep) async {
    final survivors =
        await (db.select(db.movements)
              ..orderBy([
                (t) => OrderingTerm.desc(t.at),
                (t) => OrderingTerm.desc(t.id),
              ])
              ..limit(keep))
            .get();
    if (survivors.length < keep) return;
    final keepIds = survivors.map((m) => m.id).toList();
    await (db.delete(db.movements)..where((t) => t.id.isNotIn(keepIds))).go();
  }

  // --- Settings ------------------------------------------------------------

  Future<AppSettings> _loadSettings() async {
    final prefs = {
      for (final row in await db.select(db.preferences).get())
        row.key: row.value,
    };
    final categories = await (db.select(
      db.categories,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();
    final lookups = await (db.select(
      db.lookups,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

    List<String> valuesOf(String kind) =>
        lookups.where((l) => l.kind == kind).map((l) => l.value).toList();

    final locations = valuesOf('location');
    final units = valuesOf('unit');

    return AppSettings(
      companyName: prefs['companyName'] ?? 'My Inventory',
      currency: prefs['currency'] ?? 'NGN',
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == prefs['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      categories: categories.isEmpty
          ? const []
          : categories.map((c) => c.name).toList(),
      locations: locations.isEmpty ? AppSettings.defaultLocations : locations,
      units: units.isEmpty ? AppSettings.defaultUnits : units,
      categoryColors: {
        for (final c in categories)
          if (c.swatchIndex != null) c.name: c.swatchIndex!,
      },
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    await db.transaction(() async {
      await db.batch((batch) {
        batch.insertAllOnConflictUpdate(db.preferences, [
          PreferencesCompanion.insert(
            key: 'companyName',
            value: settings.companyName,
          ),
          PreferencesCompanion.insert(
            key: 'currency',
            value: settings.currency,
          ),
          PreferencesCompanion.insert(
            key: 'themeMode',
            value: settings.themeMode.name,
          ),
        ]);
      });

      // The lists are small and order matters, so they are rewritten wholesale
      // rather than diffed.
      await db.delete(db.categories).go();
      await db.delete(db.lookups).go();
      await db.batch((batch) {
        batch.insertAll(db.categories, [
          for (final (index, name) in settings.categories.indexed)
            CategoriesCompanion.insert(
              name: name,
              swatchIndex: Value(settings.categoryColors[name]),
              position: Value(index),
            ),
        ]);
        batch.insertAll(db.lookups, [
          for (final (index, value) in settings.locations.indexed)
            LookupsCompanion.insert(
              kind: 'location',
              value: value,
              position: Value(index),
            ),
          for (final (index, value) in settings.units.indexed)
            LookupsCompanion.insert(
              kind: 'unit',
              value: value,
              position: Value(index),
            ),
        ]);
      });
    });
  }

  // --- Bulk ----------------------------------------------------------------

  /// Replaces the entire catalogue in one transaction, so a reset or a restore
  /// can never leave the database half-written.
  Future<void> replaceAll({
    required List<model.Item> items,
    required List<model.Movement> movements,
    required AppSettings settings,
  }) async {
    await db.transaction(() async {
      await db.delete(db.items).go();
      await db.delete(db.movements).go();
      await db.delete(db.suppliers).go();
      await db.delete(db.customers).go();
      await db.delete(db.purchaseOrderLines).go();
      await db.delete(db.purchaseOrders).go();
      await db.delete(db.salesOrderLines).go();
      await db.delete(db.salesOrders).go();
      await db.delete(db.stockLevels).go();
      await db.delete(db.transferLines).go();
      await db.delete(db.transfers).go();
      if (items.isNotEmpty) {
        await upsertItems(items);
        // Seeded and restored stock all starts in each item's own location.
        await db.batch(
          (batch) => batch.insertAll(db.stockLevels, [
            for (final item in items)
              if (item.quantity != 0)
                StockLevelsCompanion.insert(
                  itemId: item.id,
                  location: model.stockBin(item.location),
                  quantity: Value(item.quantity),
                ),
          ]),
        );
      }
      if (movements.isNotEmpty) await insertMovements(movements);
    });
    await saveSettings(settings);
  }

  Future<void> close() => db.close();
}

// --- Row <-> model mapping -------------------------------------------------

model.Item _toItem(ItemRow row) => model.Item(
  id: row.id,
  name: row.name,
  sku: row.sku,
  barcode: row.barcode,
  category: row.category,
  location: row.location,
  quantity: row.quantity,
  reorderLevel: row.reorderLevel,
  unit: row.unit,
  unitCost: row.unitCost,
  supplierId: row.supplierId,
  unitsPerPack: row.unitsPerPack,
  retailerPrice: row.retailerPrice,
  distributorPrice: row.distributorPrice,
  supplier: row.supplier,
  notes: row.notes,
  photo: row.photo,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

ItemsCompanion _itemRow(model.Item item) => ItemsCompanion.insert(
  id: item.id,
  name: item.name,
  sku: Value(item.sku),
  barcode: Value(item.barcode),
  category: Value(item.category),
  location: Value(item.location),
  quantity: Value(item.quantity),
  reorderLevel: Value(item.reorderLevel),
  unit: Value(item.unit),
  unitCost: Value(item.unitCost),
  supplierId: Value(item.supplierId),
  unitsPerPack: Value(item.unitsPerPack),
  retailerPrice: Value(item.retailerPrice),
  distributorPrice: Value(item.distributorPrice),
  supplier: Value(item.supplier),
  notes: Value(item.notes),
  photo: Value(item.photo),
  createdAt: item.createdAt,
  updatedAt: item.updatedAt,
);

model.Movement _toMovement(MovementRow row) => model.Movement(
  id: row.id,
  itemId: row.itemId,
  itemName: row.itemName,
  kind: model.MovementKind.values.firstWhere(
    (k) => k.name == row.kind,
    orElse: () => model.MovementKind.edit,
  ),
  before: row.before,
  after: row.after,
  note: row.note,
  actor: row.actor,
  documentId: row.documentId,
  at: row.at,
);

MovementsCompanion _movementRow(model.Movement m) => MovementsCompanion.insert(
  id: m.id,
  itemId: m.itemId,
  itemName: m.itemName,
  kind: m.kind.name,
  before: m.before,
  after: m.after,
  note: Value(m.note),
  actor: Value(m.actor),
  documentId: Value(m.documentId),
  at: m.at,
);

model.Supplier _toSupplier(SupplierRow row) => model.Supplier(
  id: row.id,
  name: row.name,
  contactName: row.contactName,
  phone: row.phone,
  email: row.email,
  address: row.address,
  leadTimeDays: row.leadTimeDays,
  paymentTerms: row.paymentTerms,
  notes: row.notes,
  archived: row.archived,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

SuppliersCompanion _supplierRow(model.Supplier s) => SuppliersCompanion.insert(
  id: s.id,
  name: s.name,
  contactName: Value(s.contactName),
  phone: Value(s.phone),
  email: Value(s.email),
  address: Value(s.address),
  leadTimeDays: Value(s.leadTimeDays),
  paymentTerms: Value(s.paymentTerms),
  notes: Value(s.notes),
  archived: Value(s.archived),
  createdAt: s.createdAt,
  updatedAt: s.updatedAt,
);

model.Customer _toCustomer(CustomerRow row) => model.Customer(
  id: row.id,
  name: row.name,
  contactName: row.contactName,
  phone: row.phone,
  email: row.email,
  address: row.address,
  priceTier: model.priceTierFrom(row.priceTier),
  notes: row.notes,
  archived: row.archived,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

CustomersCompanion _customerRow(model.Customer c) => CustomersCompanion.insert(
  id: c.id,
  name: c.name,
  contactName: Value(c.contactName),
  phone: Value(c.phone),
  email: Value(c.email),
  address: Value(c.address),
  priceTier: Value(c.priceTier.name),
  notes: Value(c.notes),
  archived: Value(c.archived),
  createdAt: c.createdAt,
  updatedAt: c.updatedAt,
);

model.PurchaseOrder _toOrder(
  PurchaseOrderRow row,
  List<model.PurchaseOrderLine> lines,
) => model.PurchaseOrder(
  id: row.id,
  reference: row.reference,
  supplierId: row.supplierId,
  supplierName: row.supplierName,
  status: model.purchaseStatusFrom(row.status),
  orderedAt: row.orderedAt,
  expectedAt: row.expectedAt,
  closedAt: row.closedAt,
  notes: row.notes,
  lines: lines,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

PurchaseOrdersCompanion _orderRow(model.PurchaseOrder o) =>
    PurchaseOrdersCompanion.insert(
      id: o.id,
      reference: o.reference,
      supplierId: Value(o.supplierId),
      supplierName: Value(o.supplierName),
      status: Value(o.status.name),
      orderedAt: Value(o.orderedAt),
      expectedAt: Value(o.expectedAt),
      closedAt: Value(o.closedAt),
      notes: Value(o.notes),
      createdAt: o.createdAt,
      updatedAt: o.updatedAt,
    );

model.PurchaseOrderLine _toLine(PurchaseOrderLineRow row) =>
    model.PurchaseOrderLine(
      id: row.id,
      itemId: row.itemId,
      itemName: row.itemName,
      quantityOrdered: row.quantityOrdered,
      quantityReceived: row.quantityReceived,
      unitCost: row.unitCost,
    );

PurchaseOrderLinesCompanion _lineRow(
  String orderId,
  model.PurchaseOrderLine line,
  int position,
) => PurchaseOrderLinesCompanion.insert(
  id: line.id,
  orderId: orderId,
  itemId: line.itemId,
  itemName: line.itemName,
  quantityOrdered: line.quantityOrdered,
  quantityReceived: Value(line.quantityReceived),
  unitCost: Value(line.unitCost),
  position: Value(position),
);

model.SalesOrder _toSalesOrder(
  SalesOrderRow row,
  List<model.SalesOrderLine> lines,
) => model.SalesOrder(
  id: row.id,
  reference: row.reference,
  customerId: row.customerId,
  customerName: row.customerName,
  priceTier: model.priceTierFrom(row.priceTier),
  status: model.salesStatusFrom(row.status),
  confirmedAt: row.confirmedAt,
  dueAt: row.dueAt,
  closedAt: row.closedAt,
  notes: row.notes,
  lines: lines,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

SalesOrdersCompanion _salesOrderRow(model.SalesOrder o) =>
    SalesOrdersCompanion.insert(
      id: o.id,
      reference: o.reference,
      customerId: Value(o.customerId),
      customerName: Value(o.customerName),
      priceTier: Value(o.priceTier.name),
      status: Value(o.status.name),
      confirmedAt: Value(o.confirmedAt),
      dueAt: Value(o.dueAt),
      closedAt: Value(o.closedAt),
      notes: Value(o.notes),
      createdAt: o.createdAt,
      updatedAt: o.updatedAt,
    );

model.SalesOrderLine _toSalesLine(SalesOrderLineRow row) =>
    model.SalesOrderLine(
      id: row.id,
      itemId: row.itemId,
      itemName: row.itemName,
      quantityOrdered: row.quantityOrdered,
      quantityFulfilled: row.quantityFulfilled,
      unitPrice: row.unitPrice,
      costOfGoods: row.costOfGoods,
    );

SalesOrderLinesCompanion _salesLineRow(
  String orderId,
  model.SalesOrderLine line,
  int position,
) => SalesOrderLinesCompanion.insert(
  id: line.id,
  orderId: orderId,
  itemId: line.itemId,
  itemName: line.itemName,
  quantityOrdered: line.quantityOrdered,
  quantityFulfilled: Value(line.quantityFulfilled),
  unitPrice: Value(line.unitPrice),
  costOfGoods: Value(line.costOfGoods),
  position: Value(position),
);
