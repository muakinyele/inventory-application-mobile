import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';

import '../data/csv_codec.dart';
import '../data/inventory_api.dart';
import '../data/inventory_loader.dart';
import '../data/inventory_repository.dart';
import '../data/seed_data.dart';
import '../models/app_settings.dart';
import '../models/invoice.dart';
import '../models/item.dart';
import '../models/movement.dart';
import '../models/party.dart';
import '../models/purchase_order.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../models/transfer.dart';

/// Where a shared catalogue's load has got to.
enum InventoryLoad {
  /// Nothing asked for yet — no session, or signed out.
  idle,
  loading,
  ready,

  /// The server could not be reached or refused. [InventoryController.loadError]
  /// says why.
  failed,
}

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
  // `this._api` is what prefer_initializing_formals asks for, but a named
  // parameter cannot be private: there would be no name a caller could write.
  InventoryController(this._repo, Snapshot initial, {InventoryApi? api})
    // ignore: prefer_initializing_formals
    : _api = api,
      _items = List.of(initial.items),
      _movements = List.of(initial.movements),
      _suppliers = List.of(initial.suppliers),
      _customers = List.of(initial.customers),
      _purchaseOrders = List.of(initial.purchaseOrders),
      _salesOrders = List.of(initial.salesOrders),
      _receipts = List.of(initial.receipts),
      _invoices = List.of(initial.invoices),
      _transfers = List.of(initial.transfers),
      _levels = Map.of(initial.levels),
      _sequences = Map.of(initial.sequences),
      _settings = initial.settings;

  static const maxMovements = 500;

  final InventoryRepository _repo;

  /// The shared inventory, when there is one.
  ///
  /// Null is the on-device path this app has always had, and is still what the
  /// widget tests build. While both exist the difference is not cosmetic: with
  /// an API the *server* owns the arithmetic, because it is the only party
  /// that can see what other devices have already done.
  final InventoryApi? _api;

  bool get isShared => _api != null;

  /// Set when the server refused a stock write because the count had moved
  /// underneath us. Cleared by the next write that succeeds.
  ///
  /// Held rather than thrown because these writes are fire-and-forget from the
  /// UI's point of view; the screen reads this and says so.
  String? stockConflict;

  /// Where the shared catalogue has got to.
  ///
  /// Only meaningful when [isShared]. On device the data is there before the
  /// first frame, so there is no state between "not started" and "ready" for a
  /// screen to show.
  InventoryLoad load = InventoryLoad.idle;

  /// Why the load failed, for the screen that has to say so.
  Object? loadError;

  final IdGenerator _ids = IdGenerator();

  List<Item> _items;
  List<Movement> _movements;
  List<Supplier> _suppliers;
  List<Customer> _customers;
  List<PurchaseOrder> _purchaseOrders;
  List<SalesOrder> _salesOrders;
  List<Receipt> _receipts;
  List<Invoice> _invoices;
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
  List<Invoice> get invoices => List.unmodifiable(_invoices);

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

  Future<Item> createItem(Item draft) async {
    final api = _api;
    if (api != null) return _createItemOnServer(api, draft);

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

  Future<void> updateItem(String id, Item draft) async {
    final api = _api;
    if (api != null) return _updateItemOnServer(api, id, draft);

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

  Future<void> deleteItem(String id) async {
    final api = _api;
    if (api != null) return _deleteItemOnServer(api, id);

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
  Future<void> adjustStock(String id, int delta, {String note = ''}) async {
    final existing = byId(id);
    if (existing == null || delta == 0) return;

    final after = max(0, existing.quantity + delta);
    if (after == existing.quantity) return;

    await _changeQuantity(
      existing,
      after,
      delta > 0 ? MovementKind.stockIn : MovementKind.stockOut,
      note,
    );
  }

  /// Sets an absolute count, e.g. after a physical stocktake.
  Future<void> setStock(
    String id,
    int quantity, {
    String note = 'Stocktake',
  }) async {
    final existing = byId(id);
    if (existing == null) return;

    final after = max(0, quantity);
    if (after == existing.quantity) return;

    await _changeQuantity(existing, after, MovementKind.adjust, note);
  }

  /// Routes a quantity change to whichever party owns the arithmetic.
  ///
  /// On device that is this class. Against a shared inventory it is the
  /// server: it is the only one that can see what other devices have already
  /// done, and it refuses a write made against a count that has since moved.
  Future<void> _changeQuantity(
    Item existing,
    int after,
    MovementKind kind,
    String note,
  ) async {
    final api = _api;
    if (api == null) {
      _applyQuantity(existing, after, kind, note);
      return;
    }
    await _changeQuantityOnServer(api, existing, after, kind, note);
  }

  /// Asks the server to move the count, and takes its answer as the truth.
  ///
  /// Deliberately not optimistic. The local path updates the screen first and
  /// persists afterwards, which is right when this device is the only writer.
  /// Here a second device may already have sold the last of it, so showing a
  /// number before the server has agreed to it would be showing a number that
  /// may be about to be withdrawn.
  Future<void> _changeQuantityOnServer(
    InventoryApi api,
    Item existing,
    int after,
    MovementKind kind,
    String note,
  ) async {
    try {
      final result = await api.adjustStock(
        itemId: existing.id,
        delta: after - existing.quantity,
        // What this device believed was current. The server compares it and
        // refuses if it has moved, rather than overwriting silently.
        expectedQuantity: existing.quantity,
        kind: kind.name,
        location: existing.location.isEmpty ? 'Unassigned' : existing.location,
        note: note,
      );

      _items = _items
          .map((i) => i.id == result.item.id ? result.item : i)
          .toList();
      _putLevels(
        result.item.id,
        _settled(
          result.item.id,
          result.item.quantity - existing.quantity,
          result.item.location,
        ),
      );
      _record(result.movement);
      stockConflict = null;
      lastWriteError = null;
    } on StockConflictException catch (conflict) {
      // The count moved under us. Pull the item back so the screen shows what
      // is actually there rather than the figure the user was working from —
      // re-applying their change blindly is the overwrite this prevents.
      stockConflict = conflict.message;
      await _refreshItem(api, existing.id);
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: stock write failed: $error');
    }
    notifyListeners();
  }

  /// Raises the invoice on the server and adopts the result.
  ///
  /// No stock arithmetic here on purpose. The server decides what each line
  /// actually takes — it can see stock this device has not heard about — and
  /// writes the movements in the same transaction as the document. Working it
  /// out here as well would produce two answers, only one of them true.
  Future<Invoice?> _issueInvoiceOnServer(
    InventoryApi api, {
    String? salesOrderId,
    String? customerId,
    required List<InvoiceLine> lines,
    double discount = 0,
    double? taxRate,
    DateTime? dueAt,
    int? termDays,
    String terms = '',
    String notes = '',
    DateTime? issuedAt,
  }) async {
    final now = DateTime.now();
    final order = salesOrderId == null ? null : salesOrderById(salesOrderId);
    final customer = customerById(customerId ?? order?.customerId);

    // An invoice raised against a sales order does not move stock a second
    // time: that order's despatch already did.
    final movesStock = order == null;

    final billed = <InvoiceLine>[];
    for (final line in lines) {
      if (line.quantity <= 0) continue;
      final item = byId(line.itemId);
      billed.add(
        InvoiceLine(
          id: line.id,
          itemId: line.itemId,
          itemName: line.itemName.isEmpty
              ? (item?.name ?? line.itemName)
              : line.itemName,
          sku: line.sku.isEmpty ? (item?.sku ?? '') : line.sku,
          unit: line.unit,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          discount: line.discount,
          // Captured now rather than read back later: profit reporting has to
          // reflect what the stock cost at the moment it was sold.
          costOfGoods: line.quantity * (item?.unitCost ?? 0),
        ),
      );
    }
    if (billed.isEmpty) return null;

    // Blank id and reference: the server mints both. Allocating a reference
    // here would let two devices raise the same invoice number.
    final draft = Invoice(
      id: '',
      reference: '',
      salesOrderId: order?.id,
      customerId: customer?.id ?? customerId,
      customerName: customer?.name ?? order?.customerName ?? '',
      lines: billed,
      discount: discount < 0 ? 0 : discount,
      taxRate: (taxRate ?? _settings.taxRate).clamp(0, 1).toDouble(),
      taxLabel: _settings.taxLabel,
      terms: terms,
      notes: notes,
      movesStock: movesStock,
      issuedAt: issuedAt ?? now,
      dueAt: dueAt ?? _dueFrom(issuedAt ?? now, termDays),
      createdAt: now,
      updatedAt: now,
    );

    try {
      final saved = await api.saveInvoice(draft);
      _invoices = [saved, ..._invoices.where((i) => i.id != saved.id)];
      if (saved.movesStock) await _refreshStockView(api);
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not raise the invoice: $error');
      notifyListeners();
      return null;
    }
  }

  /// Issues the receipt on the server and adopts the result.
  ///
  /// Same division as the invoice path: this device says what was sold, the
  /// server decides what that takes off the shelf and records the movements.
  /// A counter sale is the one that moves stock; a receipt against a sales
  /// order moves nothing, because that order's despatch already did.
  Future<Receipt?> _issueReceiptOnServer(
    InventoryApi api, {
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
  }) async {
    final now = DateTime.now();
    final order = salesOrderId == null ? null : salesOrderById(salesOrderId);
    final customer = customerById(customerId ?? order?.customerId);
    final movesStock = order == null;

    final sold = <ReceiptLine>[];
    for (final line in lines) {
      if (line.quantity <= 0) continue;
      final item = byId(line.itemId);
      sold.add(
        ReceiptLine(
          id: line.id,
          itemId: line.itemId,
          itemName: line.itemName.isEmpty
              ? (item?.name ?? line.itemName)
              : line.itemName,
          sku: line.sku.isEmpty ? (item?.sku ?? '') : line.sku,
          unit: line.unit,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          discount: line.discount,
          quantityRefunded: line.quantityRefunded,
          costOfGoods: line.quantity * (item?.unitCost ?? 0),
        ),
      );
    }
    if (sold.isEmpty) return null;

    final draft = Receipt(
      id: '',
      reference: '',
      salesOrderId: order?.id,
      customerId: customer?.id ?? customerId,
      customerName: customer?.name ?? order?.customerName ?? '',
      method: method,
      lines: sold,
      discount: discount < 0 ? 0 : discount,
      taxRate: (taxRate ?? _settings.taxRate).clamp(0, 1).toDouble(),
      taxLabel: _settings.taxLabel,
      amountPaid: amountPaid,
      notes: notes,
      cashier: cashier,
      movesStock: movesStock,
      issuedAt: issuedAt ?? now,
      createdAt: now,
      updatedAt: now,
    );

    try {
      final saved = await api.saveReceipt(draft);
      _receipts = [saved, ..._receipts.where((r) => r.id != saved.id)];
      if (saved.movesStock) await _refreshStockView(api);
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not issue the receipt: $error');
      notifyListeners();
      return null;
    }
  }

  /// Books a delivery in on the server and adopts the result.
  ///
  /// Returns the units the server actually accepted, which is not always what
  /// was asked for: it clamps each line to what is still outstanding, and this
  /// device may be working from an order another user has already received
  /// against. Counting the request rather than the answer would overstate a
  /// delivery in exactly that case.
  Future<int> _receiveOnServer(
    InventoryApi api,
    PurchaseOrder order,
    Map<String, int> received,
  ) async {
    final before = {
      for (final line in order.lines) line.id: line.quantityReceived,
    };

    try {
      // One location for the whole delivery, which is how goods actually
      // arrive — and what the endpoint takes. The on-device path books each
      // line into its own item's location instead; that difference is real,
      // and the first configured location is the closest thing to a receiving
      // bay this app knows about.
      final saved = await api.receiveGoods(
        order.id,
        received,
        location: _settings.locations.isEmpty
            ? 'Unassigned'
            : _settings.locations.first,
      );

      _purchaseOrders = _purchaseOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      await _refreshStockView(api);
      lastWriteError = null;
      notifyListeners();

      var accepted = 0;
      for (final line in saved.lines) {
        accepted += line.quantityReceived - (before[line.id] ?? 0);
      }
      return accepted;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not book the delivery: $error');
      notifyListeners();
      return 0;
    }
  }

  /// Raises a purchase order on the server.
  ///
  /// Ordering moves no stock, so there is nothing to re-read afterwards —
  /// only the delivery does, through [receivePurchaseOrder].
  Future<PurchaseOrder> _createPurchaseOrderOnServer(
    InventoryApi api, {
    String? supplierId,
    DateTime? expectedAt,
    String notes = '',
    List<PurchaseOrderLine> lines = const [],
  }) async {
    final now = DateTime.now();
    final supplier = supplierById(supplierId);

    // Blank id and reference, as with invoices: the server mints both, so two
    // devices cannot raise the same order number.
    final draft = PurchaseOrder(
      id: '',
      reference: '',
      supplierId: supplierId,
      supplierName: supplier?.name ?? '',
      expectedAt: expectedAt ?? _expectedFrom(supplier, now),
      notes: notes,
      lines: lines,
      createdAt: now,
      updatedAt: now,
    );

    try {
      final saved = await api.savePurchaseOrder(draft);
      _purchaseOrders = [
        saved,
        ..._purchaseOrders.where((o) => o.id != saved.id),
      ];
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      // Returned rather than thrown, because the local path cannot fail and
      // the caller has never had to handle one. The order is not in
      // purchaseOrders, so nothing downstream treats it as real.
      lastWriteError = error;
      debugPrint('Stockpile: could not raise the purchase order: $error');
      notifyListeners();
      return draft;
    }
  }

  /// Despatches against a sales order on the server and adopts the result.
  ///
  /// Returns what actually left, diffed from the response. The server clamps
  /// each line by what is still outstanding *and* what is on the shelf — and
  /// the shelf is shared, so another device may have sold the last of it since
  /// this order was opened. Counting the request would report a despatch that
  /// did not happen.
  Future<int> _despatchOnServer(
    InventoryApi api,
    SalesOrder order,
    Map<String, int> sent,
  ) async {
    final before = {
      for (final line in order.lines) line.id: line.quantityFulfilled,
    };

    try {
      final saved = await api.despatchGoods(
        order.id,
        sent,
        location: _settings.locations.isEmpty
            ? 'Unassigned'
            : _settings.locations.first,
      );

      _salesOrders = _salesOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      await _refreshStockView(api);
      lastWriteError = null;
      notifyListeners();

      var despatched = 0;
      for (final line in saved.lines) {
        despatched += line.quantityFulfilled - (before[line.id] ?? 0);
      }
      return despatched;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not despatch the order: $error');
      notifyListeners();
      return 0;
    }
  }

  /// Raises a sales order on the server.
  ///
  /// Committing to sell moves no stock — the despatch does — so there is
  /// nothing to re-read here.
  Future<SalesOrder> _createSalesOrderOnServer(
    InventoryApi api, {
    String? customerId,
    DateTime? dueAt,
    String notes = '',
    List<SalesOrderLine> lines = const [],
  }) async {
    final now = DateTime.now();
    final customer = customerById(customerId);

    final draft = SalesOrder(
      id: '',
      reference: '',
      customerId: customerId,
      customerName: customer?.name ?? '',
      priceTier: customer?.priceTier ?? PriceTier.retailer,
      dueAt: dueAt,
      notes: notes,
      lines: lines,
      createdAt: now,
      updatedAt: now,
    );

    try {
      final saved = await api.saveSalesOrder(draft);
      _salesOrders = [saved, ..._salesOrders.where((o) => o.id != saved.id)];
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not raise the sales order: $error');
      notifyListeners();
      return draft;
    }
  }

  /// Takes goods back on the server and adopts the result.
  ///
  /// Returns the number of *lines* something came back against, which is what
  /// the local path has always returned and what the screen reports. Counted
  /// from the response rather than the request: the server caps each line at
  /// what is still kept, so asking for more than was bought moves nothing and
  /// must not read as a refund.
  Future<int> _refundOnServer(
    InventoryApi api,
    Receipt receipt,
    Map<String, int> returned, {
    bool restock = true,
  }) async {
    final before = {
      for (final line in receipt.lines) line.id: line.quantityRefunded,
    };

    try {
      final saved = await api.refundReceipt(
        receipt.id,
        returned,
        restock: restock,
        location: _settings.locations.isEmpty
            ? 'Unassigned'
            : _settings.locations.first,
      );

      _receipts = _receipts.map((r) => r.id == saved.id ? saved : r).toList();
      // Only when the goods went back on: a broken return refunds money and
      // moves no stock, so there is nothing to re-read.
      if (restock && saved.movesStock) await _refreshStockView(api);
      lastWriteError = null;
      notifyListeners();

      var lines = 0;
      for (final line in saved.lines) {
        if (line.quantityRefunded > (before[line.id] ?? 0)) lines++;
      }
      return lines;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not refund the receipt: $error');
      notifyListeners();
      return 0;
    }
  }

  /// Adds an item to the shared catalogue.
  ///
  /// The opening quantity goes with it and the server books it in as stock
  /// arriving, so a new item's count has a movement behind it like every
  /// other — rather than appearing from nowhere on the other devices.
  Future<Item> _createItemOnServer(InventoryApi api, Item draft) async {
    try {
      final saved = await api.createItem(draft);
      _items = [saved, ..._items.where((i) => i.id != saved.id)];
      if (_learnOptions(saved)) await _persistSettingsTo(api);
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not add the item: $error');
      notifyListeners();
      return draft;
    }
  }

  /// Edits an item's details. Never its quantity — that only moves through an
  /// adjustment, so the change carries a movement explaining it.
  Future<void> _updateItemOnServer(
    InventoryApi api,
    String id,
    Item draft,
  ) async {
    final existing = byId(id);
    if (existing == null) return;

    try {
      final saved = await api.updateItem(id, draft);
      _items = _items.map((i) => i.id == id ? saved : i).toList();
      if (_learnOptions(saved)) await _persistSettingsTo(api);
      lastWriteError = null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the item: $error');
    }
    notifyListeners();
  }

  Future<void> _deleteItemOnServer(InventoryApi api, String id) async {
    try {
      await api.deleteItem(id);
      _items = _items.where((i) => i.id != id).toList();
      _levels.remove(id);
      // Movements are left alone. They carry the item's name, so the ledger
      // stays readable, and deleting them would erase the record of stock that
      // genuinely moved.
      lastWriteError = null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not delete the item: $error');
    }
    notifyListeners();
  }

  /// Writes the picker lists back after an item taught us a new one.
  ///
  /// Shared, these belong to the workspace rather than the device: a category
  /// somebody types on one screen has to appear in everybody else's picker.
  Future<void> _persistSettingsTo(InventoryApi api) async {
    try {
      await api.saveCategories([
        for (final name in _settings.categories)
          (name: name, swatchIndex: _settings.categoryColors[name] ?? 0),
      ]);
      await api.saveLookupValues('location', _settings.locations);
      await api.saveLookupValues('unit', _settings.units);
    } catch (error) {
      // The item itself saved; the picker will catch up on the next load.
      debugPrint('Stockpile: could not save the picker lists: $error');
    }
  }

  /// Creates or edits a supplier.
  ///
  /// One method for both, because the endpoint is an upsert: a blank id means
  /// the server mints one, and an id it recognises is an edit. Splitting them
  /// here would only be two names for the same request.
  Future<Supplier> _saveSupplierOnServer(
    InventoryApi api,
    Supplier draft, {
    String? id,
  }) async {
    // Rebuilt rather than copyWith: the id is the one field copyWith does not
    // take, because on device it was never editable.
    final payload = id == null
        ? draft
        : Supplier(
            id: id,
            name: draft.name,
            contactName: draft.contactName,
            phone: draft.phone,
            email: draft.email,
            address: draft.address,
            leadTimeDays: draft.leadTimeDays,
            paymentTerms: draft.paymentTerms,
            notes: draft.notes,
            archived: draft.archived,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
          );
    try {
      final saved = await api.saveSupplier(payload);
      _suppliers = [saved, ..._suppliers.where((s) => s.id != saved.id)]
        ..sort(_supplierOrder);
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the supplier: $error');
      notifyListeners();
      return payload;
    }
  }

  Future<Customer> _saveCustomerOnServer(
    InventoryApi api,
    Customer draft, {
    String? id,
  }) async {
    final payload = id == null
        ? draft
        : Customer(
            id: id,
            name: draft.name,
            contactName: draft.contactName,
            phone: draft.phone,
            email: draft.email,
            address: draft.address,
            priceTier: draft.priceTier,
            notes: draft.notes,
            archived: draft.archived,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
          );
    try {
      final saved = await api.saveCustomer(payload);
      _customers = [saved, ..._customers.where((c) => c.id != saved.id)]
        ..sort(_customerOrder);
      lastWriteError = null;
      notifyListeners();
      return saved;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the customer: $error');
      notifyListeners();
      return payload;
    }
  }

  /// Fetches the shared catalogue, replacing whatever is held.
  ///
  /// Called once a session exists — the inventory is behind authentication, so
  /// there is nothing to ask for before someone has signed in — and again
  /// after signing in on a device that was signed out.
  ///
  /// A failure leaves the previous contents alone rather than blanking them.
  /// Half a catalogue is still worth showing while the screen says the refresh
  /// did not work; an empty one looks like a workspace with nothing in it,
  /// which is the one thing this must never be mistaken for.
  Future<void> reload() async {
    final api = _api;
    if (api == null) return;

    load = InventoryLoad.loading;
    loadError = null;
    notifyListeners();

    try {
      final snapshot = await loadSharedSnapshot(api);
      _items = List.of(snapshot.items);
      _movements = List.of(snapshot.movements);
      _suppliers = List.of(snapshot.suppliers);
      _customers = List.of(snapshot.customers);
      _purchaseOrders = List.of(snapshot.purchaseOrders);
      _salesOrders = List.of(snapshot.salesOrders);
      _receipts = List.of(snapshot.receipts);
      _invoices = List.of(snapshot.invoices);
      _transfers = List.of(snapshot.transfers);
      _levels = Map.of(snapshot.levels);
      _settings = snapshot.settings;
      load = InventoryLoad.ready;
    } catch (error) {
      loadError = error;
      load = InventoryLoad.failed;
      debugPrint('Stockpile: could not load the inventory: $error');
    }
    notifyListeners();
  }

  /// Empties the held catalogue when the session ends.
  ///
  /// Signing out on a shared device has to leave nothing of the workspace on
  /// screen for whoever signs in next.
  void forgetSharedData() {
    if (_api == null) return;
    _items = [];
    _movements = [];
    _suppliers = [];
    _customers = [];
    _purchaseOrders = [];
    _salesOrders = [];
    _receipts = [];
    _invoices = [];
    _transfers = [];
    _levels = {};
    load = InventoryLoad.idle;
    loadError = null;
    notifyListeners();
  }

  /// Records a payment on the server and writes the receipt for it.
  ///
  /// The money goes first, deliberately. If the receipt then fails to save,
  /// the payment is still recorded and the document can be raised again; the
  /// other order would leave a receipt for money nothing has taken.
  ///
  /// How much was actually taken is the server's answer, not this device's
  /// arithmetic: another till may have paid against the same invoice since
  /// this screen was opened, and the balance shown here is already stale.
  Future<Receipt?> _payInvoiceOnServer(
    InventoryApi api,
    Invoice invoice,
    double amount, {
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    String cashier = '',
    DateTime? paidAt,
  }) async {
    final now = DateTime.now();

    final Invoice settled;
    final double taken;
    try {
      final result = await api.payInvoice(invoice.id, amount);
      settled = result.invoice;
      taken = result.applied;
      _invoices = _invoices
          .map((i) => i.id == settled.id ? settled : i)
          .toList();
      lastWriteError = null;
      notifyListeners();
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not record the payment: $error');
      notifyListeners();
      return null;
    }

    // The receipt carries the invoice's own lines so it prints as a proper
    // document rather than a bare figure, at zero cost of goods: the cost was
    // banked when the invoice moved the stock, and counting it again here
    // would double the cost of the sale.
    final draft = Receipt(
      id: '',
      reference: '',
      invoiceId: invoice.id,
      salesOrderId: invoice.salesOrderId,
      customerId: invoice.customerId,
      customerName: invoice.customerName,
      method: method,
      lines: [
        for (final line in invoice.lines)
          ReceiptLine(
            id: '',
            itemId: line.itemId,
            itemName: line.itemName,
            sku: line.sku,
            unit: line.unit,
            quantity: line.quantity,
            unitPrice: line.unitPrice,
            discount: line.discount,
          ),
      ],
      discount: invoice.discount,
      taxRate: invoice.taxRate,
      taxLabel: invoice.taxLabel,
      amountPaid: taken,
      notes: notes.isEmpty ? 'Payment against ${invoice.reference}' : notes,
      cashier: cashier,
      // Never: the stock left when the invoice was raised.
      movesStock: false,
      issuedAt: paidAt ?? now,
      createdAt: now,
      updatedAt: now,
    );

    try {
      final saved = await api.saveReceipt(draft);
      _receipts = [saved, ..._receipts.where((r) => r.id != saved.id)];
      notifyListeners();
      return saved;
    } catch (error) {
      // The payment stands. Saying the receipt failed is better than implying
      // the money was not taken.
      lastWriteError = error;
      debugPrint('Stockpile: payment recorded, receipt failed: $error');
      notifyListeners();
      return null;
    }
  }

  /// Re-reads what a document just changed.
  ///
  /// Items and movements only. Per-bin levels are read by the screens that
  /// show them, and fetching every item's breakdown here would be one request
  /// per item to populate something usually off screen.
  Future<void> _refreshStockView(InventoryApi api) async {
    try {
      final page = await api.items();
      _items = page.items;
      _movements = await api.movements(limit: maxMovements);
    } catch (error) {
      // The document itself saved. Reporting that is better than failing the
      // whole operation over a stale list the next load will correct.
      debugPrint('Stockpile: could not refresh after the document: $error');
    }
  }

  /// Re-reads one item after a refusal, so the screen stops showing a count
  /// the server has already disagreed with.
  Future<void> _refreshItem(InventoryApi api, String id) async {
    try {
      final fresh = await api.item(id);
      _items = _items.map((i) => i.id == id ? fresh.item : i).toList();
      _putLevels(id, fresh.stock);
    } catch (error) {
      // The conflict message still stands and is the more useful of the two.
      debugPrint('Stockpile: could not re-read $id: $error');
    }
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

  Future<Supplier> createSupplier(Supplier draft) async {
    final api = _api;
    if (api != null) return _saveSupplierOnServer(api, draft);

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

  Future<void> updateSupplier(String id, Supplier draft) async {
    final api = _api;
    if (api != null) {
      await _saveSupplierOnServer(api, draft, id: id);
      return;
    }

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

  Future<Customer> createCustomer(Customer draft) async {
    final api = _api;
    if (api != null) return _saveCustomerOnServer(api, draft);

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

  Future<void> updateCustomer(String id, Customer draft) async {
    final api = _api;
    if (api != null) {
      await _saveCustomerOnServer(api, draft, id: id);
      return;
    }

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

  Future<PurchaseOrder> createPurchaseOrder({
    String? supplierId,
    DateTime? expectedAt,
    String notes = '',
    List<PurchaseOrderLine> lines = const [],
  }) async {
    final api = _api;
    if (api != null) {
      return _createPurchaseOrderOnServer(
        api,
        supplierId: supplierId,
        expectedAt: expectedAt,
        notes: notes,
        lines: lines,
      );
    }

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
  Future<int> receivePurchaseOrder(
    String id,
    Map<String, int> received, {
    String note = '',
  }) async {
    final order = purchaseOrderById(id);
    if (order == null || !order.status.isOpen) return 0;

    final api = _api;
    if (api != null) {
      return _receiveOnServer(api, order, received);
    }

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

  /// The purchase-order counterpart of [_replaceSalesOrder], and the same
  /// reasoning: placing and cancelling both come through here.
  void _replaceOrder(PurchaseOrder order) {
    _purchaseOrders = _purchaseOrders
        .map((o) => o.id == order.id ? order : o)
        .toList();
    notifyListeners();

    final api = _api;
    if (api == null) {
      _persist(() => _repo.savePurchaseOrder(order));
      return;
    }
    _persist(() async {
      final saved = await api.savePurchaseOrder(order);
      _purchaseOrders = _purchaseOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      notifyListeners();
    });
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

  Future<SalesOrder> createSalesOrder({
    String? customerId,
    DateTime? dueAt,
    String notes = '',
    List<SalesOrderLine> lines = const [],
  }) async {
    final api = _api;
    if (api != null) {
      return _createSalesOrderOnServer(
        api,
        customerId: customerId,
        dueAt: dueAt,
        notes: notes,
        lines: lines,
      );
    }

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
  Future<int> fulfilSalesOrder(
    String id,
    Map<String, int> sent, {
    String note = '',
  }) async {
    final order = salesOrderById(id);
    if (order == null || !order.status.isOpen) return 0;

    final api = _api;
    if (api != null) {
      return _despatchOnServer(api, order, sent);
    }

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

  /// Writes an order's new state through, wherever it lives.
  ///
  /// Every status change goes through here — confirming, cancelling, closing —
  /// so this one method is what decides whether they reach anybody else. While
  /// it wrote only to the device, confirming a sale looked right until the
  /// next load and was never true for anyone but the person who did it.
  void _replaceSalesOrder(SalesOrder order) {
    _salesOrders = _salesOrders
        .map((o) => o.id == order.id ? order : o)
        .toList();
    notifyListeners();

    final api = _api;
    if (api == null) {
      _persist(() => _repo.saveSalesOrder(order));
      return;
    }
    _persist(() async {
      final saved = await api.saveSalesOrder(order);
      _salesOrders = _salesOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      notifyListeners();
    });
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
  ///
  /// A payment against an invoice is never listed: it is settled by
  /// definition, and what is still owed lives on the invoice.
  List<Receipt> get unpaidReceipts => _receipts
      .where((r) => r.status.countsAsSale && !r.isPaid && !r.isInvoicePayment)
      .toList();

  /// What one receipt actually brought in.
  ///
  /// A sale is worth its own net total. A payment against an invoice is worth
  /// the money that changed hands and no more: the receipt reprints the whole
  /// invoice so the customer can see what they are paying for, but only part
  /// of it may have been settled — and the sale itself was already counted
  /// once, at the invoice.
  static double _collected(Receipt receipt) {
    if (!receipt.status.countsAsSale) return 0;
    return receipt.isInvoicePayment ? receipt.amountPaid : receipt.netTotal;
  }

  /// Everything taken across the counter, net of refunds and voids, plus
  /// money collected against invoices. This is cash in — a different measure
  /// from revenue, which is recognised when the goods go out.
  double get takings => _receipts.fold(0.0, (sum, r) => sum + _collected(r));

  /// Takings for one day, which is what a till reconciliation is against.
  double takingsOn(DateTime day) {
    return _receipts
        .where((r) => _sameDay(r.issuedAt, day))
        .fold(0.0, (sum, r) => sum + _collected(r));
  }

  /// Takings split by how they were paid, so a till can be counted against
  /// the cash line rather than the whole day's total.
  Map<PaymentMethod, double> takingsByMethod({DateTime? day}) {
    final totals = <PaymentMethod, double>{};
    for (final receipt in _receipts) {
      if (day != null && !_sameDay(receipt.issuedAt, day)) continue;
      if (!receipt.status.countsAsSale) continue;
      totals[receipt.method] =
          (totals[receipt.method] ?? 0) + _collected(receipt);
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
  Future<Receipt?> issueReceipt({
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
  }) async {
    if (lines.isEmpty) return null;

    final api = _api;
    if (api != null) {
      return _issueReceiptOnServer(
        api,
        salesOrderId: salesOrderId,
        customerId: customerId,
        method: method,
        lines: lines,
        discount: discount,
        taxRate: taxRate,
        amountPaid: amountPaid,
        notes: notes,
        cashier: cashier,
        issuedAt: issuedAt,
      );
    }

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
  Future<int> refundReceipt(
    String id,
    Map<String, int> returned, {
    bool restock = true,
    String note = '',
  }) async {
    final receipt = receiptById(id);
    if (receipt == null || !receipt.status.isRefundable) return 0;

    final api = _api;
    if (api != null) {
      return _refundOnServer(api, receipt, returned, restock: restock);
    }

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
  Future<bool> voidReceipt(String id, {String reason = ''}) async {
    final receipt = receiptById(id);
    if (receipt == null ||
        receipt.status != ReceiptStatus.issued ||
        receipt.unitsRefunded > 0) {
      return false;
    }

    final api = _api;
    if (api != null) {
      try {
        final voided = await api.voidReceipt(id, reason: reason);
        _receipts = _receipts
            .map((r) => r.id == voided.id ? voided : r)
            .toList();
        // The server put the stock back and wrote the movement for it, so
        // the counts here are stale until re-read.
        if (voided.movesStock) await _refreshStockView(api);
        lastWriteError = null;
        notifyListeners();
        return true;
      } catch (error) {
        lastWriteError = error;
        debugPrint('Stockpile: could not void the receipt: $error');
        notifyListeners();
        return false;
      }
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

  // --- Invoices ------------------------------------------------------------

  Invoice? invoiceById(String id) {
    for (final invoice in _invoices) {
      if (invoice.id == id) return invoice;
    }
    return null;
  }

  List<Invoice> invoicesForCustomer(String customerId) =>
      _invoices.where((i) => i.customerId == customerId).toList();

  List<Invoice> invoicesForSalesOrder(String salesOrderId) =>
      _invoices.where((i) => i.salesOrderId == salesOrderId).toList();

  /// Invoices still owed money, soonest due first. What the business is
  /// waiting to be paid.
  List<Invoice> get openInvoices {
    final open = _invoices.where((i) => i.status.isCollectable).toList();
    open.sort((a, b) {
      final aDue = a.dueAt;
      final bDue = b.dueAt;
      if (aDue == null && bDue == null) return 0;
      if (aDue == null) return 1;
      if (bDue == null) return -1;
      return aDue.compareTo(bDue);
    });
    return open;
  }

  List<Invoice> get overdueInvoices =>
      _invoices.where((i) => i.isOverdue).toList();

  /// Total owed across every live invoice — the receivables book.
  double get totalReceivable =>
      _invoices.fold(0.0, (sum, i) => sum + i.outstanding);

  /// Payments taken against an invoice, newest first, as the invoice's own
  /// page shows them.
  List<InvoicePayment> paymentsForInvoice(String invoiceId) {
    return [
      for (final receipt in _receipts)
        if (receipt.invoiceId == invoiceId && receipt.status.countsAsSale)
          InvoicePayment(
            receiptId: receipt.id,
            reference: receipt.reference,
            amount: receipt.amountPaid,
            method: receipt.method,
            at: receipt.issuedAt,
          ),
    ];
  }

  /// The lines an invoice for [order] would carry: what that sale has sent,
  /// priced as quoted. Shares the receipt's rule — you bill for goods that
  /// have actually gone out.
  List<InvoiceLine> invoiceLinesForSalesOrder(SalesOrder order) {
    return [
      for (final line in order.lines)
        if (line.quantityFulfilled > 0)
          InvoiceLine(
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

  /// Raises an invoice for a credit sale.
  ///
  /// The mirror of [issueReceipt], and it moves stock on the same rule: a
  /// standalone credit sale is the moment goods change hands, so it takes
  /// them off the shelf and banks what they cost. An invoice billing a sales
  /// order moves nothing — that order's despatch already did.
  ///
  /// Quantities on a standalone invoice are clamped to what is on the shelf,
  /// and a line left with nothing to sell is dropped. Returns null when no
  /// line survives that.
  /// Raises an invoice.
  ///
  /// Shared, the whole stock calculation below belongs to the
  /// server: it is the only party that can see what other devices have already
  /// sold, and it records the movements in the same transaction as the document.
  /// This device sends the lines and adopts what comes back.
  Future<Invoice?> issueInvoice({
    String? salesOrderId,
    String? customerId,
    required List<InvoiceLine> lines,
    double discount = 0,
    double? taxRate,
    DateTime? dueAt,
    int? termDays,
    String terms = '',
    String notes = '',
    DateTime? issuedAt,
  }) async {
    if (lines.isEmpty) return null;

    final api = _api;
    if (api != null) {
      return _issueInvoiceOnServer(
        api,
        salesOrderId: salesOrderId,
        customerId: customerId,
        lines: lines,
        discount: discount,
        taxRate: taxRate,
        dueAt: dueAt,
        termDays: termDays,
        terms: terms,
        notes: notes,
        issuedAt: issuedAt,
      );
    }

    final now = DateTime.now();
    final order = salesOrderId == null ? null : salesOrderById(salesOrderId);
    final movesStock = order == null;
    final customer = customerById(customerId ?? order?.customerId);

    final invoiceId = _uid();
    final reference = _nextReference('INV');

    final billed = <InvoiceLine>[];
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};
    // Two lines can name the same item, so the running total is tracked here
    // rather than read back off `_items`, which has not been written yet.
    final remaining = <String, int>{};

    for (final line in lines) {
      if (line.quantity <= 0) continue;
      final item = byId(line.itemId);

      if (!movesStock || item == null) {
        billed.add(line);
        continue;
      }

      final onHand = remaining[item.id] ?? item.quantity;
      final quantity = line.quantity.clamp(0, onHand < 0 ? 0 : onHand);
      if (quantity <= 0) continue;

      final after = onHand - quantity;
      remaining[item.id] = after;

      billed.add(
        InvoiceLine(
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
          'Sold on account on $reference',
          documentId: invoiceId,
        ),
      );
    }

    if (billed.isEmpty) return null;

    final invoice = Invoice(
      id: invoiceId,
      reference: reference,
      salesOrderId: order?.id,
      customerId: customer?.id ?? customerId,
      customerName: customer?.name ?? order?.customerName ?? '',
      lines: billed,
      discount: discount < 0 ? 0 : discount,
      taxRate: (taxRate ?? _settings.taxRate).clamp(0, 1).toDouble(),
      taxLabel: _settings.taxLabel,
      terms: terms,
      notes: notes,
      movesStock: movesStock,
      issuedAt: issuedAt ?? now,
      dueAt: dueAt ?? _dueFrom(issuedAt ?? now, termDays),
      createdAt: now,
      updatedAt: now,
    );

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }
    _invoices = [invoice, ..._invoices];
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        invoice: invoice,
      );
      if (movements.isNotEmpty) await _repo.trimMovements(maxMovements);
    });
    return invoice;
  }

  DateTime? _dueFrom(DateTime from, int? termDays) {
    if (termDays == null || termDays <= 0) return null;
    return from.add(Duration(days: termDays));
  }

  /// Records money received against an invoice, and issues the receipt for it.
  ///
  /// This is the whole point of the credit flow: the customer gets a receipt
  /// for what they just paid, and the invoice's balance comes down by the
  /// same amount. The receipt moves no stock — the invoice already did — so
  /// nothing is sold twice, and reporting counts the sale once, at the
  /// invoice.
  ///
  /// A payment is never taken past the balance, so an invoice cannot end up
  /// showing change it did not give. Returns the receipt, or null when there
  /// was nothing to collect.
  Future<Receipt?> payInvoice(
    String id,
    double amount, {
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    String cashier = '',
    DateTime? paidAt,
  }) async {
    final invoice = invoiceById(id);
    if (invoice == null || !invoice.status.isCollectable) return null;
    if (amount <= 0 || invoice.balanceDue <= 0) return null;

    final api = _api;
    if (api != null) {
      return _payInvoiceOnServer(
        api,
        invoice,
        amount,
        method: method,
        notes: notes,
        cashier: cashier,
        paidAt: paidAt,
      );
    }

    final now = DateTime.now();
    final taken = amount.clamp(0, invoice.balanceDue).toDouble();

    // The receipt carries the invoice's own lines so it prints as a proper
    // document rather than a bare figure, but at zero cost of goods: the cost
    // was banked when the invoice moved the stock, and counting it again here
    // would double the cost of the sale.
    final receipt = Receipt(
      id: _uid(),
      reference: _nextReference('RC'),
      invoiceId: invoice.id,
      salesOrderId: invoice.salesOrderId,
      customerId: invoice.customerId,
      customerName: invoice.customerName,
      method: method,
      lines: [
        for (final line in invoice.lines)
          ReceiptLine(
            id: _uid(),
            itemId: line.itemId,
            itemName: line.itemName,
            sku: line.sku,
            unit: line.unit,
            quantity: line.quantity,
            unitPrice: line.unitPrice,
            discount: line.discount,
          ),
      ],
      discount: invoice.discount,
      taxRate: invoice.taxRate,
      taxLabel: invoice.taxLabel,
      amountPaid: taken,
      notes: notes.isEmpty ? 'Payment against ${invoice.reference}' : notes,
      cashier: cashier,
      movesStock: false,
      issuedAt: paidAt ?? now,
      createdAt: now,
      updatedAt: now,
    );

    final paid = invoice.amountPaid + taken;
    final settled = invoice.total - paid < 0.005;
    final updated = invoice.copyWith(
      amountPaid: paid,
      status: settled ? InvoiceStatus.paid : InvoiceStatus.partPaid,
      closedAt: settled ? now : null,
      updatedAt: now,
    );

    _receipts = [receipt, ..._receipts];
    _invoices = _invoices.map((i) => i.id == id ? updated : i).toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(receipt: receipt, invoice: updated);
    });
    return receipt;
  }

  /// Strikes an invoice off in full.
  ///
  /// Only one nothing has been paid against can be cancelled; once money has
  /// arrived the document has a history worth keeping. A cancellation puts
  /// back exactly the stock the invoice took, and nothing when it never moved
  /// any.
  bool cancelInvoice(String id, {String reason = ''}) {
    final invoice = invoiceById(id);
    if (invoice == null ||
        invoice.status != InvoiceStatus.open ||
        invoice.amountPaid > 0) {
      return false;
    }

    final now = DateTime.now();
    final touchedItems = <Item>[];
    final movements = <Movement>[];
    final binWrites = <String, Map<String, int>>{};

    if (invoice.movesStock) {
      // Summed by item first: an invoice may name the same item on two lines,
      // and each has to go back against the running total.
      final byItem = <String, int>{};
      for (final line in invoice.lines) {
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
            'Cancelled ${invoice.reference}',
            documentId: invoice.id,
          ),
        );
      }
    }

    final updated = invoice.copyWith(
      status: InvoiceStatus.cancelled,
      closedAt: now,
      cancelledReason: reason,
      updatedAt: now,
    );

    _applyTouched(touchedItems);
    for (final movement in movements) {
      _record(movement);
    }
    _invoices = _invoices.map((i) => i.id == id ? updated : i).toList();
    notifyListeners();

    _persist(() async {
      await _repo.commitStockChange(
        items: touchedItems,
        levels: binWrites,
        movements: movements,
        invoice: updated,
      );
      if (movements.isNotEmpty) await _repo.trimMovements(maxMovements);
    });
    return true;
  }

  /// Removes a cancelled invoice from the file. Only a cancellation is ever
  /// deletable: a live invoice is a claim on money, and one with payments
  /// against it carries history that has to stay.
  void deleteInvoice(String id) {
    final invoice = invoiceById(id);
    if (invoice == null || invoice.status != InvoiceStatus.cancelled) return;
    _invoices = _invoices.where((i) => i.id != id).toList();
    notifyListeners();
    _persist(() => _repo.deleteInvoice(id));
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

  Future<void> updateSettings(AppSettings next) async {
    _settings = next;
    notifyListeners();

    final api = _api;
    if (api == null) {
      _persist(() => _repo.saveSettings(next));
      return;
    }

    // These belong to the workspace, not the device — the company name on an
    // invoice has to be the same one everybody else prints. Written straight
    // through rather than optimistically: the screen already shows the new
    // value, and a failure is reported rather than silently reverted.
    try {
      await api.savePreferences({
        'companyName': next.companyName,
        'currency': next.currency,
        'companyAddress': next.companyAddress,
        'companyPhone': next.companyPhone,
        'companyEmail': next.companyEmail,
        'taxRate': next.taxRate.toString(),
        'taxLabel': next.taxLabel,
        'receiptFooter': next.receiptFooter,
      });
      await _persistSettingsTo(api);
      lastWriteError = null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the settings: $error');
    }
    notifyListeners();
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
    _invoices = const [];
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
