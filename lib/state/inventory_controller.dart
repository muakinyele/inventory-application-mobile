import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';

import '../data/csv_codec.dart';
import '../data/inventory_repository.dart';
import '../data/seed_data.dart';
import '../models/app_settings.dart';
import '../models/item.dart';
import '../models/movement.dart';
import '../models/party.dart';
import '../models/purchase_order.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../models/transfer.dart';

/// Owns the in-memory view of the catalogue and is the only thing that mutates
/// it. Reads stay synchronous so widgets can build without a future; every
/// write is applied in memory, published, and persisted to SQLite through
/// [InventoryRepository].
///
/// Any change that touches a quantity also appends a [Movement], so the ledger
/// is a by-product of the write path rather than something each screen has to
/// remember to record. Category edits deliberately append nothing — the ledger
/// records stock, not metadata.
class InventoryController extends ChangeNotifier {
  InventoryController(this._repo, Snapshot initial)
    : _items = List.of(initial.items),
      _movements = List.of(initial.movements),
      _suppliers = List.of(initial.suppliers),
      _customers = List.of(initial.customers),
      _purchaseOrders = List.of(initial.purchaseOrders),
      _salesOrders = List.of(initial.salesOrders),
      _receipts = List.of(initial.receipts),
      _transfers = List.of(initial.transfers),
      _levels = Map.of(initial.levels),
      _sequences = Map.of(initial.sequences),
      _settings = initial.settings;

  static const maxMovements = 500;

  final InventoryRepository _repo;
  final IdGenerator _ids = IdGenerator();

  List<Item> _items;
  List<Movement> _movements;
  List<Supplier> _suppliers;
  List<Customer> _customers;
  List<PurchaseOrder> _purchaseOrders;
  List<SalesOrder> _salesOrders;
  List<Receipt> _receipts;
  List<Transfer> _transfers;

  /// Stock broken down by bin: item id -> location -> quantity. The bins for
  /// an item always sum to that item's quantity.
  Map<String, Map<String, int>> _levels;
  Map<String, int> _sequences;
  AppSettings _settings;

  /// Set when a database write fails, so a screen can surface it rather than
  /// letting the UI silently diverge from what is on disk.
  Object? lastWriteError;

  List<Item> get items => List.unmodifiable(_items);
  List<Movement> get movements => List.unmodifiable(_movements);
  List<Supplier> get suppliers => List.unmodifiable(_suppliers);
  List<Customer> get customers => List.unmodifiable(_customers);
  List<PurchaseOrder> get purchaseOrders => List.unmodifiable(_purchaseOrders);
  List<SalesOrder> get salesOrders => List.unmodifiable(_salesOrders);
  List<Receipt> get receipts => List.unmodifiable(_receipts);

  /// Orders that can still receive stock, soonest expected first.
  List<PurchaseOrder> get openPurchaseOrders {
    final open = _purchaseOrders.where((o) => o.status.isOpen).toList();
    open.sort((a, b) {
      final aDate = a.expectedAt;
      final bDate = b.expectedAt;
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return aDate.compareTo(bDate);
    });
    return open;
  }

  PurchaseOrder? purchaseOrderById(String id) {
    for (final order in _purchaseOrders) {
      if (order.id == id) return order;
    }
    return null;
  }

  AppSettings get settings => _settings;

  // --- Derived figures -----------------------------------------------------

  int get totalUnits => _items.fold(0, (sum, i) => sum + i.quantity);
  double get totalStockValue =>
      _items.fold(0.0, (sum, i) => sum + i.stockValue);
  double get totalRetailValue =>
      _items.fold(0.0, (sum, i) => sum + i.retailValue);

  /// Everything at or below its reorder level, emptiest first.
  List<Item> get needsAttention {
    final flagged = _items.where((i) => i.status != StockStatus.ok).toList();
    int rank(Item i) => i.quantity <= 0 ? 0 : 1;
    flagged.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.quantity.compareTo(b.quantity);
    });
    return flagged;
  }

  Item? byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  Supplier? supplierById(String? id) {
    if (id == null) return null;
    for (final s in _suppliers) {
      if (s.id == id) return s;
    }
    return null;
  }

  Customer? customerById(String? id) {
    if (id == null) return null;
    for (final c in _customers) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The name to show for an item's supplier: the linked record if there is
  /// one, otherwise the free-text name it was imported with.
  String supplierNameFor(Item item) =>
      supplierById(item.supplierId)?.name ?? item.supplier;

  int itemCountForSupplier(String supplierId) =>
      _items.where((i) => i.supplierId == supplierId).length;

  Item? byCode(String code) {
    for (final item in _items) {
      if (item.barcode == code || item.sku == code) return item;
    }
    return null;
  }

  // --- Item mutations ------------------------------------------------------

  Item createItem(Item draft) {
    final now = DateTime.now();
    final item = Item(
      id: _uid(),
      name: draft.name,
      sku: draft.sku,
      barcode: draft.barcode,
      category: draft.category,
      location: draft.location,
      quantity: draft.quantity,
      reorderLevel: draft.reorderLevel,
      unit: draft.unit,
      unitCost: draft.unitCost,
      retailerPrice: draft.retailerPrice,
      distributorPrice: draft.distributorPrice,
      supplier: draft.supplier,
      supplierId: draft.supplierId,
      unitsPerPack: draft.unitsPerPack,
      notes: draft.notes,
      photo: draft.photo,
      createdAt: now,
      updatedAt: now,
    );

    _items = [item, ..._items];
    _bookToBins(item.id, item.quantity, item.location);
    final movement = _movement(
      item,
      MovementKind.create,
      0,
      item.quantity,
      'Item created',
    );
    _record(movement);
    final settingsChanged = _learnOptions(item);
    notifyListeners();

    _persist(() async {
      await _repo.upsertItem(item);
      await _repo.insertMovement(movement);
      if (settingsChanged) await _repo.saveSettings(_settings);
    });
    return item;
  }

  void updateItem(String id, Item draft) {
    final existing = byId(id);
    if (existing == null) return;

    final updated = draft.copyWith(updatedAt: DateTime.now());
    final quantityChanged = existing.quantity != updated.quantity;

    _items = _items.map((i) => i.id == id ? updated : i).toList();
    // Home bin first, so a quantity typed on the form lands where the item
    // now lives rather than where it used to.
    _relocateHome(id, existing.location, updated.location);
    _bookToBins(id, updated.quantity - existing.quantity, updated.location);
    final movement = _movement(
      updated,
      quantityChanged ? MovementKind.adjust : MovementKind.edit,
      existing.quantity,
      updated.quantity,
      quantityChanged ? 'Quantity changed while editing' : 'Details updated',
    );
    _record(movement);
    final settingsChanged = _learnOptions(updated);
    notifyListeners();

    _persist(() async {
      await _repo.upsertItem(updated);
      await _repo.insertMovement(movement);
      if (settingsChanged) await _repo.saveSettings(_settings);
    });
  }

  void deleteItem(String id) {
    final existing = byId(id);
    if (existing == null) return;

    _items = _items.where((i) => i.id != id).toList();
    _dropBins(id);
    final movement = _movement(
      existing,
      MovementKind.delete,
      existing.quantity,
      0,
      'Item deleted',
    );
    _record(movement);
    notifyListeners();

    _persist(() async {
      await _repo.deleteItem(id);
      await _repo.insertMovement(movement);
    });
  }

  /// Applies a signed change. Stock can never go below zero — a bigger "out"
  /// than you hold empties the bin instead of going below it.
  void adjustStock(String id, int delta, {String note = ''}) {
    final existing = byId(id);
    if (existing == null || delta == 0) return;

    final after = max(0, existing.quantity + delta);
    if (after == existing.quantity) return;

    _applyQuantity(
      existing,
      after,
      delta > 0 ? MovementKind.stockIn : MovementKind.stockOut,
      note,
    );
  }

  /// Sets an absolute count, e.g. after a physical stocktake.
  void setStock(String id, int quantity, {String note = 'Stocktake'}) {
    final existing = byId(id);
    if (existing == null) return;

    final after = max(0, quantity);
    if (after == existing.quantity) return;

    _applyQuantity(existing, after, MovementKind.adjust, note);
  }

  void _applyQuantity(
    Item existing,
    int after,
    MovementKind kind,
    String note,
  ) {
    final updated = existing.copyWith(
      quantity: after,
      updatedAt: DateTime.now(),
    );
    _items = _items.map((i) => i.id == updated.id ? updated : i).toList();
    _bookToBins(updated.id, after - existing.quantity, updated.location);
    final movement = _movement(updated, kind, existing.quantity, after, note);
    _record(movement);
    notifyListeners();

    _persist(() async {
      await _repo.upsertItem(updated);
      await _repo.insertMovement(movement);
    });
  }

  int importDrafts(List<ItemDraft> drafts) {
    if (drafts.isEmpty) return 0;
    final now = DateTime.now();
    final imported = drafts
        .map(
          (d) => Item(
            id: _uid(),
            name: d.name,
            sku: d.sku,
            barcode: d.barcode,
            category: d.category,
            location: d.location,
            quantity: d.quantity,
            reorderLevel: d.reorderLevel,
            unit: d.unit,
            unitCost: d.unitCost,
            retailerPrice: d.retailerPrice,
            distributorPrice: d.distributorPrice,
            supplier: d.supplier,
            notes: d.notes,
            createdAt: now,
            updatedAt: now,
          ),
        )
        .toList();

    final movements = imported
        .map(
          (i) => _movement(
            i,
            MovementKind.create,
            0,
            i.quantity,
            'Imported from CSV',
          ),
        )
        .toList();

    _items = [...imported, ..._items];
    _movements = [...movements, ..._movements].take(maxMovements).toList();
    // Imported rows carry one location each, so each lands whole in its bin.
    final importedBins = <String, Map<String, int>>{};
    for (final i in imported) {
      if (i.quantity == 0) continue;
      importedBins[i.id] = {stockBin(i.location): i.quantity};
    }
    _levels = {..._levels, ...importedBins};

    final categories = {..._settings.categories};
    final locations = {..._settings.locations};
    final units = {..._settings.units};
    for (final i in imported) {
      if (i.category.isNotEmpty) categories.add(i.category);
      if (i.location.isNotEmpty) locations.add(i.location);
      if (i.unit.isNotEmpty) units.add(i.unit);
    }
    _settings = _settings.copyWith(
      categories: categories.toList(),
      locations: locations.toList(),
      units: units.toList(),
    );
    notifyListeners();

    _persist(() async {
      await _repo.upsertItems(imported);
      for (final entry in importedBins.entries) {
        await _repo.saveLevels(entry.key, entry.value);
      }
      await _repo.insertMovements(movements);
      await _repo.saveSettings(_settings);
      await _repo.trimMovements(maxMovements);
    });
    return imported.length;
  }

  // --- Suppliers -----------------------------------------------------------

  Supplier createSupplier(Supplier draft) {
    final now = DateTime.now();
    final supplier = draft.copyWith(updatedAt: now);
    final created = Supplier(
      id: _uid(),
      name: supplier.name,
      contactName: supplier.contactName,
      phone: supplier.phone,
      email: supplier.email,
      address: supplier.address,
      leadTimeDays: supplier.leadTimeDays,
      paymentTerms: supplier.paymentTerms,
      notes: supplier.notes,
      archived: supplier.archived,
      createdAt: now,
      updatedAt: now,
    );
    _suppliers = [..._suppliers, created]..sort(_supplierOrder);
    notifyListeners();
    _persist(() => _repo.upsertSupplier(created));
    return created;
  }

  void updateSupplier(String id, Supplier draft) {
    if (supplierById(id) == null) return;
    final updated = draft.copyWith(updatedAt: DateTime.now());
    _suppliers = _suppliers.map((s) => s.id == id ? updated : s).toList()
      ..sort(_supplierOrder);
    notifyListeners();
    _persist(() => _repo.upsertSupplier(updated));
  }

  /// Unlinks the supplier from its items before removing it, so no item is
  /// left pointing at a record that no longer exists. The item keeps the
  /// supplier's name as free text, so history stays readable.
  void deleteSupplier(String id) {
    final supplier = supplierById(id);
    if (supplier == null) return;

    final now = DateTime.now();
    final touched = _items
        .where((i) => i.supplierId == id)
        .map(
          (i) => i.copyWith(
            supplier: supplier.name,
            clearSupplierId: true,
            updatedAt: now,
          ),
        )
        .toList();
    _applyTouched(touched);
    _suppliers = _suppliers.where((s) => s.id != id).toList();
    notifyListeners();

    _persist(() async {
      if (touched.isNotEmpty) await _repo.upsertItems(touched);
      await _repo.deleteSupplier(id);
    });
  }

  // --- Customers -----------------------------------------------------------

  Customer createCustomer(Customer draft) {
    final now = DateTime.now();
    final created = Customer(
      id: _uid(),
      name: draft.name,
      contactName: draft.contactName,
      phone: draft.phone,
      email: draft.email,
      address: draft.address,
      priceTier: draft.priceTier,
      notes: draft.notes,
      archived: draft.archived,
      createdAt: now,
      updatedAt: now,
    );
    _customers = [..._customers, created]..sort(_customerOrder);
    notifyListeners();
    _persist(() => _repo.upsertCustomer(created));
    return created;
  }

  void updateCustomer(String id, Customer draft) {
    if (customerById(id) == null) return;
    final updated = draft.copyWith(updatedAt: DateTime.now());
    _customers = _customers.map((c) => c.id == id ? updated : c).toList()
      ..sort(_customerOrder);
    notifyListeners();
    _persist(() => _repo.upsertCustomer(updated));
  }

  void deleteCustomer(String id) {
    if (customerById(id) == null) return;
    _customers = _customers.where((c) => c.id != id).toList();
    notifyListeners();
    _persist(() => _repo.deleteCustomer(id));
  }

  // --- Purchase orders -----------------------------------------------------

  /// The next document reference for a prefix. Counters are persisted, so a
  /// reference is never reused even after its document is deleted.
  String _nextReference(String prefix) {
    final next = (_sequences[prefix] ?? 0) + 1;
    _sequences = {..._sequences, prefix: next};
    _persist(() => _repo.saveSequence(prefix, next));
    return '$prefix-${next.toString().padLeft(4, '0')}';
  }

  PurchaseOrder createPurchaseOrder({
    String? supplierId,
    DateTime? expectedAt,
    String notes = '',
    List<PurchaseOrderLine> lines = const [],
  }) {
    final now = DateTime.now();
    final supplier = supplierById(supplierId);
    final order = PurchaseOrder(
      id: _uid(),
      reference: _nextReference('PO'),
      supplierId: supplierId,
      supplierName: supplier?.name ?? '',
      expectedAt: expectedAt ?? _expectedFrom(supplier, now),
      notes: notes,
      lines: lines,
      createdAt: now,
      updatedAt: now,
    );
    _purchaseOrders = [order, ..._purchaseOrders];
    notifyListeners();
    _persist(() => _repo.savePurchaseOrder(order));
    return order;
  }

  /// Defaults the expected date from the supplier's lead time, which is the
  /// whole reason lead time is recorded.
  DateTime? _expectedFrom(Supplier? supplier, DateTime from) {
    if (supplier == null || supplier.leadTimeDays <= 0) return null;
    return from.add(Duration(days: supplier.leadTimeDays));
  }

  /// Edits are only accepted while the order is still a draft; once it has
  /// been placed, the document is a record of what was agreed.
  void updatePurchaseOrder(
    String id, {
    String? supplierId,
    bool clearSupplier = false,
    DateTime? expectedAt,
    bool clearExpectedAt = false,
    String? notes,
    List<PurchaseOrderLine>? lines,
  }) {
    final existing = purchaseOrderById(id);
    if (existing == null || !existing.status.isEditable) return;

    final resolvedSupplierId = clearSupplier
        ? null
        : (supplierId ?? existing.supplierId);
    final updated = existing.copyWith(
      supplierId: resolvedSupplierId,
      supplierName: supplierById(resolvedSupplierId)?.name ?? '',
      expectedAt: expectedAt,
      clearExpectedAt: clearExpectedAt,
      notes: notes,
      lines: lines,
      updatedAt: DateTime.now(),
    );
    _replaceOrder(updated);
  }

  /// Places the order. Nothing moves in stock — this only opens it for
  /// receiving.
  void placePurchaseOrder(String id) {
    final existing = purchaseOrderById(id);
    if (existing == null ||
        existing.status != PurchaseStatus.draft ||
        existing.lines.isEmpty) {
      return;
    }
    final now = DateTime.now();
    _replaceOrder(
      existing.copyWith(
        status: PurchaseStatus.ordered,
        orderedAt: now,
        updatedAt: now,
      ),
    );
  }

  void cancelPurchaseOrder(String id) {
    final existing = purchaseOrderById(id);
    if (existing == null || existing.status == PurchaseStatus.received) return;
    final now = DateTime.now();
    _replaceOrder(
      existing.copyWith(
        status: PurchaseStatus.cancelled,
        closedAt: now,
        updatedAt: now,
      ),
    );
  }

  void deletePurchaseOrder(String id) {
    final existing = purchaseOrderById(id);
    // Anything that has moved stock stays on file; only paperwork is deletable.
    if (existing == null || existing.unitsReceived > 0) return;
    _purchaseOrders = _purchaseOrders.where((o) => o.id != id).toList();
    notifyListeners();
    _persist(() => _repo.deletePurchaseOrder(id));
  }

  /// Books stock in against an order.
  ///
  /// [received] maps line id to the quantity arriving now. Each line raises a
  /// stock movement tagged with the order, and the item's unit cost is rolled
  /// forward as a weighted average of what was already held and what arrived —
  /// so cost follows what was actually paid rather than the last price typed.
  ///
  /// Returns the number of lines that moved.
  int receivePurchaseOrder(
    String id,
    Map<String, int> received, {
    String note = '',
  }) {
    final order = purchaseOrderById(id);
    if (order == null || !order.status.isOpen) return 0;

    final now = DateTime.now();
    final updatedLines = <PurchaseOrderLine>[];
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};

    for (final line in order.lines) {
      final wanted = received[line.id] ?? 0;
      final quantity = wanted.clamp(0, line.outstanding);
      if (quantity <= 0) {
        updatedLines.add(line);
        continue;
      }

      updatedLines.add(
        line.copyWith(quantityReceived: line.quantityReceived + quantity),
      );

      final item = byId(line.itemId);
      if (item == null) continue;

      final after = item.quantity + quantity;
      final updatedItem = item.copyWith(
        quantity: after,
        unitCost: _rollForwardCost(item, quantity, line.unitCost),
        updatedAt: now,
      );
      touchedItems.add(updatedItem);
      _putLevels(item.id, _settled(item.id, quantity, item.location));
      binWrites[item.id] = _levels[item.id] ?? const <String, int>{};
      movements.add(
        _movement(
          updatedItem,
          MovementKind.stockIn,
          item.quantity,
          after,
          note.isEmpty ? 'Received on ${order.reference}' : note,
          documentId: order.id,
        ),
      );
    }

    if (movements.isEmpty) return 0;

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }

    final settled = updatedLines.every((l) => l.isComplete);
    final updatedOrder = order.copyWith(
      lines: updatedLines,
      status: settled ? PurchaseStatus.received : PurchaseStatus.partial,
      closedAt: settled ? now : null,
      updatedAt: now,
    );
    _purchaseOrders = _purchaseOrders
        .map((o) => o.id == updatedOrder.id ? updatedOrder : o)
        .toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        purchaseOrder: updatedOrder,
      );
      await _repo.trimMovements(maxMovements);
    });
    return movements.length;
  }

  /// Weighted average of stock already held and stock arriving. Falls back to
  /// the incoming cost when there was nothing on hand to average against.
  double _rollForwardCost(Item item, int quantity, double incomingCost) {
    if (incomingCost <= 0) return item.unitCost;
    if (item.quantity <= 0) return incomingCost;
    final existingValue = item.quantity * item.unitCost;
    final incomingValue = quantity * incomingCost;
    return (existingValue + incomingValue) / (item.quantity + quantity);
  }

  void _replaceOrder(PurchaseOrder order) {
    _purchaseOrders = _purchaseOrders
        .map((o) => o.id == order.id ? order : o)
        .toList();
    notifyListeners();
    _persist(() => _repo.savePurchaseOrder(order));
  }

  // --- Sales orders --------------------------------------------------------

  /// Sales that can still send stock, soonest promised first.
  List<SalesOrder> get openSalesOrders {
    final open = _salesOrders.where((o) => o.status.isOpen).toList();
    open.sort((a, b) {
      final aDate = a.dueAt;
      final bDate = b.dueAt;
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return aDate.compareTo(bDate);
    });
    return open;
  }

  SalesOrder? salesOrderById(String id) {
    for (final order in _salesOrders) {
      if (order.id == id) return order;
    }
    return null;
  }

  /// The tier a sale to this customer is quoted at. Retailer is the default
  /// for a walk-in with no customer record.
  PriceTier priceTierFor(String? customerId) =>
      customerById(customerId)?.priceTier ?? PriceTier.retailer;

  SalesOrder createSalesOrder({
    String? customerId,
    DateTime? dueAt,
    String notes = '',
    List<SalesOrderLine> lines = const [],
  }) {
    final now = DateTime.now();
    final customer = customerById(customerId);
    final order = SalesOrder(
      id: _uid(),
      reference: _nextReference('SO'),
      customerId: customerId,
      customerName: customer?.name ?? '',
      priceTier: customer?.priceTier ?? PriceTier.retailer,
      dueAt: dueAt,
      notes: notes,
      lines: lines,
      createdAt: now,
      updatedAt: now,
    );
    _salesOrders = [order, ..._salesOrders];
    notifyListeners();
    _persist(() => _repo.saveSalesOrder(order));
    return order;
  }

  /// Edits are only accepted while the sale is still a draft; once confirmed,
  /// the document is a record of what was quoted.
  void updateSalesOrder(
    String id, {
    String? customerId,
    bool clearCustomer = false,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? notes,
    List<SalesOrderLine>? lines,
  }) {
    final existing = salesOrderById(id);
    if (existing == null || !existing.status.isEditable) return;

    final resolvedCustomerId = clearCustomer
        ? null
        : (customerId ?? existing.customerId);
    final customer = customerById(resolvedCustomerId);
    final updated = existing.copyWith(
      customerId: resolvedCustomerId,
      customerName: customer?.name ?? '',
      priceTier: customer?.priceTier ?? PriceTier.retailer,
      dueAt: dueAt,
      clearDueAt: clearDueAt,
      notes: notes,
      lines: lines,
      updatedAt: DateTime.now(),
    );
    _replaceSalesOrder(updated);
  }

  /// Confirms the sale. Nothing moves in stock — this only opens it for
  /// despatch.
  void confirmSalesOrder(String id) {
    final existing = salesOrderById(id);
    if (existing == null ||
        existing.status != SalesStatus.draft ||
        existing.lines.isEmpty) {
      return;
    }
    final now = DateTime.now();
    _replaceSalesOrder(
      existing.copyWith(
        status: SalesStatus.confirmed,
        confirmedAt: now,
        updatedAt: now,
      ),
    );
  }

  void cancelSalesOrder(String id) {
    final existing = salesOrderById(id);
    if (existing == null || existing.status == SalesStatus.fulfilled) return;
    final now = DateTime.now();
    _replaceSalesOrder(
      existing.copyWith(
        status: SalesStatus.cancelled,
        closedAt: now,
        updatedAt: now,
      ),
    );
  }

  void deleteSalesOrder(String id) {
    final existing = salesOrderById(id);
    // Anything that has moved stock stays on file; only paperwork is deletable.
    if (existing == null || existing.unitsFulfilled > 0) return;
    _salesOrders = _salesOrders.where((o) => o.id != id).toList();
    notifyListeners();
    _persist(() => _repo.deleteSalesOrder(id));
  }

  /// The most that can be sent on a line right now: what is still outstanding,
  /// capped by what is actually on the shelf.
  int sendableOn(SalesOrder order, SalesOrderLine line) {
    final onHand = byId(line.itemId)?.quantity ?? 0;
    return line.outstanding.clamp(0, onHand < 0 ? 0 : onHand);
  }

  /// Sends stock against a sale.
  ///
  /// [sent] maps line id to the quantity going out now. Each line raises a
  /// stock movement tagged with the order, and banks what that stock cost at
  /// today's average, so margin is fixed at the moment of despatch rather
  /// than recomputed from a cost that has since moved.
  ///
  /// A line never sends more than is on the shelf: stock is not allowed to go
  /// negative, and the balance simply stays outstanding.
  ///
  /// Returns the number of lines that moved.
  int fulfilSalesOrder(String id, Map<String, int> sent, {String note = ''}) {
    final order = salesOrderById(id);
    if (order == null || !order.status.isOpen) return 0;

    final now = DateTime.now();
    final updatedLines = <SalesOrderLine>[];
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};

    for (final line in order.lines) {
      final item = byId(line.itemId);
      final onHand = item?.quantity ?? 0;
      final wanted = sent[line.id] ?? 0;
      final quantity = wanted.clamp(0, line.outstanding).clamp(0, onHand);
      if (quantity <= 0 || item == null) {
        updatedLines.add(line);
        continue;
      }

      updatedLines.add(
        line.copyWith(
          quantityFulfilled: line.quantityFulfilled + quantity,
          costOfGoods: line.costOfGoods + quantity * item.unitCost,
        ),
      );

      final after = item.quantity - quantity;
      final updatedItem = item.copyWith(quantity: after, updatedAt: now);
      touchedItems.add(updatedItem);
      _putLevels(item.id, _settled(item.id, -quantity, item.location));
      binWrites[item.id] = _levels[item.id] ?? const <String, int>{};
      movements.add(
        _movement(
          updatedItem,
          MovementKind.stockOut,
          item.quantity,
          after,
          note.isEmpty ? 'Sold on ${order.reference}' : note,
          documentId: order.id,
        ),
      );
    }

    if (movements.isEmpty) return 0;

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }

    final settled = updatedLines.every((l) => l.isComplete);
    final updatedOrder = order.copyWith(
      lines: updatedLines,
      status: settled ? SalesStatus.fulfilled : SalesStatus.partial,
      closedAt: settled ? now : null,
      updatedAt: now,
    );
    _salesOrders = _salesOrders
        .map((o) => o.id == updatedOrder.id ? updatedOrder : o)
        .toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        salesOrder: updatedOrder,
      );
      await _repo.trimMovements(maxMovements);
    });
    return movements.length;
  }

  void _replaceSalesOrder(SalesOrder order) {
    _salesOrders = _salesOrders
        .map((o) => o.id == order.id ? order : o)
        .toList();
    notifyListeners();
    _persist(() => _repo.saveSalesOrder(order));
  }

  // --- Receipts ------------------------------------------------------------

  Receipt? receiptById(String id) {
    for (final receipt in _receipts) {
      if (receipt.id == id) return receipt;
    }
    return null;
  }

  /// Receipts raised against a sales order, newest first.
  List<Receipt> receiptsForSalesOrder(String salesOrderId) =>
      _receipts.where((r) => r.salesOrderId == salesOrderId).toList();

  /// Receipts issued to a customer, newest first.
  List<Receipt> receiptsForCustomer(String customerId) =>
      _receipts.where((r) => r.customerId == customerId).toList();

  /// Receipts that are still owed money. An account sale is expected to sit
  /// here until it is settled; a cash sale here means someone under-paid.
  List<Receipt> get unpaidReceipts => _receipts
      .where((r) => r.status.countsAsSale && !r.isPaid)
      .toList();

  /// Everything taken across the counter, net of refunds and voids.
  double get takings =>
      _receipts.fold(0.0, (sum, r) => sum + r.netTotal);

  /// Takings for one day, which is what a till reconciliation is against.
  double takingsOn(DateTime day) {
    return _receipts
        .where((r) => _sameDay(r.issuedAt, day))
        .fold(0.0, (sum, r) => sum + r.netTotal);
  }

  /// Takings split by how they were paid, so a till can be counted against
  /// the cash line rather than the whole day's total.
  Map<PaymentMethod, double> takingsByMethod({DateTime? day}) {
    final totals = <PaymentMethod, double>{};
    for (final receipt in _receipts) {
      if (day != null && !_sameDay(receipt.issuedAt, day)) continue;
      if (!receipt.status.countsAsSale) continue;
      totals[receipt.method] = (totals[receipt.method] ?? 0) + receipt.netTotal;
    }
    return totals;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The lines a receipt for [order] would carry: what that sale has actually
  /// sent, priced as it was quoted. Nothing despatched, nothing to receipt.
  List<ReceiptLine> receiptLinesForSalesOrder(SalesOrder order) {
    return [
      for (final line in order.lines)
        if (line.quantityFulfilled > 0)
          ReceiptLine(
            id: _uid(),
            itemId: line.itemId,
            itemName: line.itemName,
            sku: byId(line.itemId)?.sku ?? '',
            unit: byId(line.itemId)?.unit ?? 'pcs',
            quantity: line.quantityFulfilled,
            unitPrice: line.unitPrice,
            costOfGoods: line.costOfGoods,
          ),
    ];
  }

  /// Issues a receipt.
  ///
  /// A counter sale — one with no [salesOrderId] — is the moment the goods
  /// change hands, so it takes the stock off the shelf itself and banks what
  /// it cost at today's average, exactly as a despatch does. A receipt raised
  /// against a sales order moves nothing: that order's despatch already did,
  /// and booking it twice would take the stock out twice over.
  ///
  /// Quantities on a counter sale are clamped to what is actually on the
  /// shelf — stock is never allowed to go negative — and a line left with
  /// nothing to sell is dropped. Returns null when no line survives that.
  Receipt? issueReceipt({
    String? salesOrderId,
    String? customerId,
    PaymentMethod method = PaymentMethod.cash,
    required List<ReceiptLine> lines,
    double discount = 0,
    double? taxRate,
    double amountPaid = 0,
    String notes = '',
    String cashier = '',
    DateTime? issuedAt,
  }) {
    if (lines.isEmpty) return null;

    final now = DateTime.now();
    final order = salesOrderId == null ? null : salesOrderById(salesOrderId);
    final movesStock = order == null;
    final customer = customerById(customerId ?? order?.customerId);

    // Minted up front so every ledger row can carry the document it came from,
    // the same way a transfer does.
    final receiptId = _uid();
    final reference = _nextReference('RC');

    final priced = <ReceiptLine>[];
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};
    // Two lines can name the same item, so the running total is tracked here
    // rather than read back off `_items` — which has not been written yet.
    final remaining = <String, int>{};

    for (final line in lines) {
      if (line.quantity <= 0) continue;
      final item = byId(line.itemId);

      if (!movesStock || item == null) {
        // Nothing to take off the shelf: either the sale already despatched,
        // or the item has since been deleted and only its name survives.
        priced.add(line);
        continue;
      }

      final onHand = remaining[item.id] ?? item.quantity;
      final quantity = line.quantity.clamp(0, onHand < 0 ? 0 : onHand);
      if (quantity <= 0) continue;

      final after = onHand - quantity;
      remaining[item.id] = after;

      priced.add(
        ReceiptLine(
          id: line.id,
          itemId: line.itemId,
          itemName: line.itemName.isEmpty ? item.name : line.itemName,
          sku: line.sku.isEmpty ? item.sku : line.sku,
          unit: line.unit,
          quantity: quantity,
          unitPrice: line.unitPrice,
          discount: line.discount,
          costOfGoods: quantity * item.unitCost,
        ),
      );

      final updatedItem = item.copyWith(quantity: after, updatedAt: now);
      touchedItems.add(updatedItem);
      _putLevels(item.id, _settled(item.id, -quantity, item.location));
      binWrites[item.id] = _levels[item.id] ?? const <String, int>{};
      movements.add(
        _movement(
          updatedItem,
          MovementKind.stockOut,
          onHand,
          after,
          'Sold at the counter on $reference',
          documentId: receiptId,
        ),
      );
    }

    if (priced.isEmpty) return null;

    final receipt = Receipt(
      id: receiptId,
      reference: reference,
      salesOrderId: order?.id,
      customerId: customer?.id ?? customerId,
      customerName: customer?.name ?? order?.customerName ?? '',
      method: method,
      lines: priced,
      discount: discount < 0 ? 0 : discount,
      taxRate: (taxRate ?? _settings.taxRate).clamp(0, 1).toDouble(),
      taxLabel: _settings.taxLabel,
      amountPaid: amountPaid < 0 ? 0 : amountPaid,
      notes: notes,
      cashier: cashier,
      movesStock: movesStock,
      issuedAt: issuedAt ?? now,
      createdAt: now,
      updatedAt: now,
    );

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }
    _receipts = [receipt, ..._receipts];
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        receipt: receipt,
      );
      if (movements.isNotEmpty) await _repo.trimMovements(maxMovements);
    });
    return receipt;
  }

  /// Books goods back in against a receipt.
  ///
  /// [returned] maps line id to the quantity coming back, each clamped to what
  /// is left un-refunded on that line. When [restock] is true the goods go
  /// back on the shelf and the ledger says so; a refund of something spoiled
  /// or already written off passes false, which returns the money without
  /// inventing stock that is not there.
  ///
  /// Returns the number of lines that moved.
  int refundReceipt(
    String id,
    Map<String, int> returned, {
    bool restock = true,
    String note = '',
  }) {
    final receipt = receiptById(id);
    if (receipt == null || !receipt.status.isRefundable) return 0;

    final now = DateTime.now();
    final updatedLines = <ReceiptLine>[];
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};
    var refunded = 0;

    for (final line in receipt.lines) {
      final wanted = returned[line.id] ?? 0;
      final quantity = wanted.clamp(0, line.quantityKept);
      if (quantity <= 0) {
        updatedLines.add(line);
        continue;
      }

      refunded++;
      updatedLines.add(
        line.copyWith(quantityRefunded: line.quantityRefunded + quantity),
      );

      final item = byId(line.itemId);
      if (!restock || item == null) continue;

      final after = item.quantity + quantity;
      final updatedItem = item.copyWith(quantity: after, updatedAt: now);
      touchedItems.add(updatedItem);
      _putLevels(item.id, _settled(item.id, quantity, item.location));
      binWrites[item.id] = _levels[item.id] ?? const <String, int>{};
      movements.add(
        _movement(
          updatedItem,
          MovementKind.stockIn,
          item.quantity,
          after,
          note.isEmpty ? 'Returned on ${receipt.reference}' : note,
          documentId: receipt.id,
        ),
      );
    }

    if (refunded == 0) return 0;

    final settled = updatedLines.every((l) => l.isFullyRefunded);
    final updated = receipt.copyWith(
      lines: updatedLines,
      status: settled ? ReceiptStatus.refunded : ReceiptStatus.partRefunded,
      refundedAt: now,
      updatedAt: now,
    );

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }
    _receipts = _receipts.map((r) => r.id == id ? updated : r).toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        receipt: updated,
      );
      if (movements.isNotEmpty) await _repo.trimMovements(maxMovements);
    });
    return refunded;
  }

  /// Strikes a receipt off in full — the counter equivalent of tearing it up.
  ///
  /// Only a receipt nothing has come back against can be voided; once goods
  /// have been returned the document has a history worth keeping, and the rest
  /// should be refunded rather than erased. A void puts back exactly the stock
  /// the receipt took, and nothing when the receipt never moved any.
  bool voidReceipt(String id, {String reason = ''}) {
    final receipt = receiptById(id);
    if (receipt == null ||
        receipt.status != ReceiptStatus.issued ||
        receipt.unitsRefunded > 0) {
      return false;
    }

    final now = DateTime.now();
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};

    if (receipt.movesStock) {
      // Summed by item first: a receipt may name the same item on two lines,
      // and each has to be put back against the running total, not the one
      // the item started with.
      final byItem = <String, int>{};
      for (final line in receipt.lines) {
        if (line.quantity <= 0) continue;
        byItem[line.itemId] = (byItem[line.itemId] ?? 0) + line.quantity;
      }
      for (final entry in byItem.entries) {
        final item = byId(entry.key);
        if (item == null) continue;
        final after = item.quantity + entry.value;
        final updatedItem = item.copyWith(quantity: after, updatedAt: now);
        touchedItems.add(updatedItem);
        _putLevels(item.id, _settled(item.id, entry.value, item.location));
        binWrites[item.id] = _levels[item.id] ?? const <String, int>{};
        movements.add(
          _movement(
            updatedItem,
            MovementKind.stockIn,
            item.quantity,
            after,
            'Voided ${receipt.reference}',
            documentId: receipt.id,
          ),
        );
      }
    }

    final updated = receipt.copyWith(
      status: ReceiptStatus.voided,
      voidedAt: now,
      voidReason: reason,
      updatedAt: now,
    );

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }
    _receipts = _receipts.map((r) => r.id == id ? updated : r).toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        receipt: updated,
      );
      if (movements.isNotEmpty) await _repo.trimMovements(maxMovements);
    });
    return true;
  }

  /// Records money received against a receipt that was left owing — settling
  /// an account sale. Never takes the paid figure past the total, so a
  /// receipt can not end up showing change it never gave.
  void settleReceipt(String id, double amount, {PaymentMethod? method}) {
    final receipt = receiptById(id);
    if (receipt == null || amount <= 0 || !receipt.status.countsAsSale) return;

    final updated = receipt.copyWith(
      amountPaid: receipt.amountPaid + amount.clamp(0, receipt.balanceDue),
      method: method,
      updatedAt: DateTime.now(),
    );
    _receipts = _receipts.map((r) => r.id == id ? updated : r).toList();
    notifyListeners();
    _persist(() => _repo.saveReceipt(updated));
  }

  /// Removes a voided receipt from the file. Only a void is ever deletable:
  /// a live receipt is the customer's proof of purchase, and one with refunds
  /// against it carries history that has to stay.
  void deleteReceipt(String id) {
    final receipt = receiptById(id);
    if (receipt == null || receipt.status != ReceiptStatus.voided) return;
    _receipts = _receipts.where((r) => r.id != id).toList();
    notifyListeners();
    _persist(() => _repo.deleteReceipt(id));
  }

  // --- Stock by location ---------------------------------------------------

  /// One item's stock broken down by bin, fullest first. The values always
  /// sum to the item's quantity.
  Map<String, int> stockByLocation(String itemId) {
    final bins = _levels[itemId];
    if (bins == null || bins.isEmpty) return const {};
    final sorted = bins.entries.toList()
      ..sort((a, b) {
        final byQuantity = b.value.compareTo(a.value);
        return byQuantity != 0 ? byQuantity : a.key.compareTo(b.key);
      });
    return {for (final e in sorted) e.key: e.value};
  }

  int onHandAt(String itemId, String location) =>
      _levels[itemId]?[stockBin(location)] ?? 0;

  /// Units held at each location across the whole catalogue, fullest first.
  Map<String, int> get unitsByLocation {
    final totals = <String, int>{};
    for (final bins in _levels.values) {
      for (final entry in bins.entries) {
        totals[entry.key] = (totals[entry.key] ?? 0) + entry.value;
      }
    }
    return _sortedByValue(totals);
  }

  /// Stock value held at each location, at cost.
  Map<String, double> get valueByLocation {
    final totals = <String, double>{};
    for (final entry in _levels.entries) {
      final cost = byId(entry.key)?.unitCost ?? 0;
      for (final bin in entry.value.entries) {
        totals[bin.key] = (totals[bin.key] ?? 0) + bin.value * cost;
      }
    }
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {for (final e in sorted) e.key: e.value};
  }

  /// Locations that actually hold something, plus every location the settings
  /// know about, so a transfer can name an empty destination.
  List<String> get transferLocations {
    final names = <String>{
      ..._settings.locations.map(stockBin),
      ...unitsByLocation.keys,
    };
    final sorted = names.toList()..sort();
    return sorted;
  }

  Map<String, int> _sortedByValue(Map<String, int> input) {
    final sorted = input.entries.toList()
      ..sort((a, b) {
        final byValue = b.value.compareTo(a.value);
        return byValue != 0 ? byValue : a.key.compareTo(b.key);
      });
    return {for (final e in sorted) e.key: e.value};
  }

  /// Books a change in an item's total into its bins.
  ///
  /// Stock arriving lands in [into]. Stock leaving is taken from [into] first
  /// and then from the fullest of the other bins, so the breakdown drains in
  /// the order a person would pick it and can never go negative — which keeps
  /// the bins summing to the item's quantity whatever route the change took.
  Map<String, int> _settled(String itemId, int delta, String into) {
    final bins = {...?_levels[itemId]};
    if (delta == 0) return bins;
    final bin = stockBin(into);

    if (delta > 0) {
      bins[bin] = (bins[bin] ?? 0) + delta;
      return bins;
    }

    var remaining = -delta;
    final others = bins.keys.where((k) => k != bin).toList()
      ..sort((a, b) => bins[b]!.compareTo(bins[a]!));
    for (final key in [bin, ...others]) {
      if (remaining <= 0) break;
      final held = bins[key] ?? 0;
      if (held <= 0) continue;
      final taken = held < remaining ? held : remaining;
      bins[key] = held - taken;
      remaining -= taken;
    }
    return bins;
  }

  void _putLevels(String itemId, Map<String, int> bins) {
    final kept = {
      for (final e in bins.entries)
        if (e.value > 0) e.key: e.value,
    };
    final next = {..._levels};
    if (kept.isEmpty) {
      next.remove(itemId);
    } else {
      next[itemId] = kept;
    }
    _levels = next;
  }

  /// Applies a change in an item's total to its bins, in memory and on disk.
  void _bookToBins(String itemId, int delta, String into) {
    if (delta == 0) return;
    _putLevels(itemId, _settled(itemId, delta, into));
    final bins = _levels[itemId] ?? const <String, int>{};
    _persist(() => _repo.saveLevels(itemId, bins));
  }

  /// Moves whatever sits in an item's old home bin to its new one, used when
  /// the item's location is edited. Stock parked in other bins stays put —
  /// renaming where something lives should not silently relocate the rest.
  void _relocateHome(String itemId, String from, String to) {
    final fromBin = stockBin(from);
    final toBin = stockBin(to);
    if (fromBin == toBin) return;
    final bins = {...?_levels[itemId]};
    final moving = bins[fromBin] ?? 0;
    if (moving <= 0) return;
    bins.remove(fromBin);
    bins[toBin] = (bins[toBin] ?? 0) + moving;
    _putLevels(itemId, bins);
    final saved = _levels[itemId] ?? const <String, int>{};
    _persist(() => _repo.saveLevels(itemId, saved));
  }

  void _dropBins(String itemId) {
    final next = {..._levels}..remove(itemId);
    _levels = next;
    _persist(() => _repo.deleteLevels(itemId));
  }

  /// Rebuilds every breakdown from the items themselves. Used for a reset, a
  /// restore or a CSV import, where the incoming data carries one location.
  void _rebuildBins(List<Item> items) {
    _levels = {
      for (final item in items)
        if (item.quantity != 0)
          item.id: {stockBin(item.location): item.quantity},
    };
  }

  // --- Transfers -----------------------------------------------------------

  List<Transfer> get transfers => List.unmodifiable(_transfers);

  Transfer? transferById(String id) {
    for (final transfer in _transfers) {
      if (transfer.id == id) return transfer;
    }
    return null;
  }

  /// Moves stock between two locations and records it.
  ///
  /// Each line is clamped to what is actually held at [fromLocation], so a
  /// transfer can never invent stock or leave a bin negative. The item's total
  /// is untouched — the goods have not left the business, only the shelf —
  /// so the ledger entry carries the same before and after.
  ///
  /// Returns the transfer, or null when nothing could move.
  Transfer? recordTransfer({
    required String fromLocation,
    required String toLocation,
    required List<TransferLine> lines,
    String notes = '',
  }) {
    final from = stockBin(fromLocation);
    final to = stockBin(toLocation);
    if (from == to || lines.isEmpty) return null;

    final now = DateTime.now();
    // Minted up front so every ledger row can carry the document it came from.
    final transferId = _uid();
    final moved = <TransferLine>[];
    final movements = <Movement>[];
    final writes = <String, Map<String, int>>{};

    for (final line in lines) {
      final item = byId(line.itemId);
      if (item == null) continue;
      final available = onHandAt(item.id, from);
      final quantity = line.quantity.clamp(0, available);
      if (quantity <= 0) continue;

      final bins = {...?_levels[item.id]};
      bins[from] = (bins[from] ?? 0) - quantity;
      bins[to] = (bins[to] ?? 0) + quantity;
      _putLevels(item.id, bins);
      writes[item.id] = _levels[item.id] ?? const <String, int>{};

      moved.add(
        TransferLine(
          id: line.id,
          itemId: line.itemId,
          itemName: item.name,
          quantity: quantity,
        ),
      );
      movements.add(
        _movement(
          item,
          MovementKind.transfer,
          item.quantity,
          item.quantity,
          'Moved $quantity from $from to $to',
          documentId: transferId,
        ),
      );
    }

    if (moved.isEmpty) return null;

    final transfer = Transfer(
      id: transferId,
      reference: _nextReference('TR'),
      fromLocation: from,
      toLocation: to,
      notes: notes,
      lines: moved,
      movedAt: now,
      createdAt: now,
    );
    _transfers = [transfer, ..._transfers];
    for (final movement in movements) {
      _record(movement);
    }
    _learnLocations([from, to]);
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        levels: writes,
        movements: movements,
        transfer: transfer,
      );
      await _repo.trimMovements(maxMovements);
    });
    return transfer;
  }

  /// Folds any new bin name into the settings list so the pickers keep up.
  void _learnLocations(Iterable<String> names) {
    var next = _settings;
    for (final name in names) {
      if (name.isNotEmpty && !next.locations.contains(name)) {
        next = next.copyWith(locations: [...next.locations, name]);
      }
    }
    if (identical(next, _settings)) return;
    _settings = next;
    _persist(() => _repo.saveSettings(_settings));
  }

  // --- Categories ----------------------------------------------------------

  void addCategory(String name, int swatchIndex) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (_settings.categories.any(
      (c) => c.toLowerCase() == trimmed.toLowerCase(),
    )) {
      return;
    }
    _settings = _settings.copyWith(
      categories: [..._settings.categories, trimmed],
      categoryColors: {..._settings.categoryColors, trimmed: swatchIndex},
    );
    notifyListeners();
    _persist(() => _repo.saveSettings(_settings));
  }

  void renameCategory(String from, String to, int swatchIndex) {
    final trimmed = to.trim();
    if (trimmed.isEmpty) return;

    final colors = {..._settings.categoryColors}
      ..remove(from)
      ..[trimmed] = swatchIndex;
    _settings = _settings.copyWith(
      categories: _settings.categories
          .map((c) => c == from ? trimmed : c)
          .toList(),
      categoryColors: colors,
    );

    final now = DateTime.now();
    final touched = from == trimmed
        ? const <Item>[]
        : _items
              .where((i) => i.category == from)
              .map((i) => i.copyWith(category: trimmed, updatedAt: now))
              .toList();
    _applyTouched(touched);
    notifyListeners();

    _persist(() async {
      if (touched.isNotEmpty) await _repo.upsertItems(touched);
      await _repo.saveSettings(_settings);
    });
  }

  /// Removes the category and clears it from the items that used it, which
  /// leaves their stock untouched and marks them uncategorised.
  void deleteCategory(String name) {
    _settings = _settings.copyWith(
      categories: _settings.categories.where((c) => c != name).toList(),
      categoryColors: {..._settings.categoryColors}..remove(name),
    );

    final now = DateTime.now();
    final touched = _items
        .where((i) => i.category == name)
        .map((i) => i.copyWith(category: '', updatedAt: now))
        .toList();
    _applyTouched(touched);
    notifyListeners();

    _persist(() async {
      if (touched.isNotEmpty) await _repo.upsertItems(touched);
      await _repo.saveSettings(_settings);
    });
  }

  int _supplierOrder(Supplier a, Supplier b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  int _customerOrder(Customer a, Customer b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  void _applyTouched(List<Item> touched) {
    if (touched.isEmpty) return;
    final replacements = {for (final i in touched) i.id: i};
    _items = _items.map((i) => replacements[i.id] ?? i).toList();
  }

  // --- Settings and bulk ---------------------------------------------------

  void updateSettings(AppSettings next) {
    _settings = next;
    notifyListeners();
    _persist(() => _repo.saveSettings(next));
  }

  void loadSampleData() => _replace(
    items: seedItems(),
    movements: seedMovements(),
    settings: const AppSettings(),
  );

  void eraseAll() => _replace(
    items: const [],
    movements: const [],
    settings: const AppSettings(),
  );

  void _replace({
    required List<Item> items,
    required List<Movement> movements,
    required AppSettings settings,
  }) {
    _items = List.of(items);
    _movements = List.of(movements);
    _suppliers = const [];
    _customers = const [];
    _purchaseOrders = const [];
    _salesOrders = const [];
    _receipts = const [];
    _transfers = const [];
    _rebuildBins(_items);
    _settings = settings;
    notifyListeners();
    _persist(
      () => _repo.replaceAll(
        items: items,
        movements: movements,
        settings: settings,
      ),
    );
  }

  // --- Internals -----------------------------------------------------------

  void _record(Movement movement) {
    _movements = [movement, ..._movements].take(maxMovements).toList();
  }

  /// Folds any new category / location / unit into settings so the pickers
  /// stay in step with what items actually use. Returns whether it changed.
  bool _learnOptions(Item item) {
    var next = _settings;
    if (item.category.isNotEmpty && !next.categories.contains(item.category)) {
      next = next.copyWith(categories: [...next.categories, item.category]);
    }
    if (item.location.isNotEmpty && !next.locations.contains(item.location)) {
      next = next.copyWith(locations: [...next.locations, item.location]);
    }
    if (item.unit.isNotEmpty && !next.units.contains(item.unit)) {
      next = next.copyWith(units: [...next.units, item.unit]);
    }
    if (identical(next, _settings)) return false;
    _settings = next;
    return true;
  }

  Movement _movement(
    Item item,
    MovementKind kind,
    int before,
    int after,
    String note, {
    String? documentId,
  }) {
    return Movement(
      id: _uid(),
      itemId: item.id,
      itemName: item.name,
      kind: kind,
      before: before,
      after: after,
      note: note,
      documentId: documentId,
      at: DateTime.now(),
    );
  }

  /// Writes are fire-and-forget: the UI already reflects the change, and a
  /// failed write must not block or crash the interaction. The error is kept
  /// so a screen can surface it.
  void _persist(Future<void> Function() write) {
    write().then((_) => lastWriteError = null).catchError((Object error) {
      lastWriteError = error;
      debugPrint('Stockpile: database write failed: $error');
    });
  }

  String _uid() => _ids.next();
}
