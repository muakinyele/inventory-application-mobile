import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';

import '../data/auth_api.dart' show AuthApiException;
import '../data/csv_codec.dart';
import '../data/inventory_api.dart';
import '../data/inventory_loader.dart';
import '../data/snapshot.dart';
import '../data/seed_data.dart';
import '../models/app_settings.dart';
import '../models/cancelled_sale_issue.dart';
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
  /// [loadedDocuments] says which document collections [initial] already
  /// carries, so they are not fetched again.
  ///
  /// Empty from a real sign-in, because the snapshot no longer brings
  /// documents down; a test that seeds them says so, and without that the
  /// first screen to open would fetch over the top of its own fixture.
  InventoryController(
    this._api,
    Snapshot initial, {
    Set<DocumentSet> loadedDocuments = const {},
  }) : _loadedDocuments = {...loadedDocuments},
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

  /// The shared inventory.
  ///
  /// Not optional any more. The app kept an on-device path alongside this one
  /// through the migration, which was useful while both had to work and became
  /// a liability once only one did: every write had two implementations, and
  /// the tests exercised the one that no longer ships.
  final InventoryApi _api;

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

  // --- Documents, fetched when something needs them ------------------------
  //
  // THEY USED TO COME DOWN AT SIGN-IN, all five lists with all their lines,
  // before the dashboard could draw — and the dashboard reads none of them. A
  // workspace with a year of trading waited on its whole history to see
  // today's stock.
  //
  // Now a screen says what it needs and waits only for that. The flags below
  // are per collection rather than one "documents loaded" bit, because the
  // receipts page should not pay for purchase orders.

  final Set<DocumentSet> _loadedDocuments;
  final Map<DocumentSet, Future<void>> _documentLoads = {};
  final Map<DocumentSet, Object> _documentErrors = {};

  /// Whether every collection in [wanted] is already here.
  bool documentsReady(Set<DocumentSet> wanted) =>
      wanted.every(_loadedDocuments.contains);

  /// Whether a fetch for any of [wanted] is in flight.
  bool documentsLoading(Set<DocumentSet> wanted) =>
      wanted.any(_documentLoads.containsKey);

  /// What went wrong fetching any of [wanted], if anything did.
  ///
  /// A screen waiting on documents has to be able to tell "still coming" from
  /// "this failed", because they look identical from behind a spinner and only
  /// one of them is worth waiting for.
  Object? documentError(Set<DocumentSet> wanted) {
    for (final kind in wanted) {
      final failure = _documentErrors[kind];
      if (failure != null) return failure;
    }
    return null;
  }

  /// Fetches any of [wanted] that are not loaded yet, and waits for them.
  ///
  /// Safe to call on every build: a collection already loaded returns at once,
  /// and one being fetched is awaited rather than fetched again — two screens
  /// asking for receipts at the same moment make one request.
  Future<void> ensureDocuments(Set<DocumentSet> wanted) async {
    final pending = <Future<void>>[];
    for (final kind in wanted) {
      if (_loadedDocuments.contains(kind)) continue;
      // Clear the last failure first: the screen reads this to decide between
      // a spinner and an error, and a retry that still showed the old error
      // would look like it had failed again before it had even been tried.
      _documentErrors.remove(kind);
      pending.add(_documentLoads[kind] ??= _fetchDocuments(kind));
    }
    if (pending.isEmpty) return;
    await Future.wait(pending);
  }

  Future<void> _fetchDocuments(DocumentSet kind) async {
    try {
      switch (kind) {
        case DocumentSet.invoices:
          _invoices = await _api.invoices();
        case DocumentSet.receipts:
          _receipts = await _api.receipts();
        case DocumentSet.purchaseOrders:
          _purchaseOrders = await _api.purchaseOrders();
        case DocumentSet.salesOrders:
          _salesOrders = await _api.salesOrders();
        case DocumentSet.transfers:
          _transfers = await _api.transfers();
      }
      _loadedDocuments.add(kind);
      _documentErrors.remove(kind);
      lastWriteError = null;
    } catch (error) {
      // Left unloaded so the next screen that needs it tries again, rather
      // than showing an empty list for the rest of the session as though the
      // workspace had none.
      debugPrint('Stockpile: could not load ${kind.name}: $error');
      _documentErrors[kind] = error;
    } finally {
      _documentLoads.remove(kind);
      notifyListeners();
    }
  }

  /// Forgets what has been fetched, so the next screen asks again.
  ///
  /// Used after anything that replaces the workspace wholesale — a restore, an
  /// erase, a reload — where keeping the old lists would show documents that
  /// no longer exist.
  void _forgetDocuments() {
    _loadedDocuments.clear();
    _documentLoads.clear();
    _documentErrors.clear();
    _purchaseOrders = const [];
    _salesOrders = const [];
    _receipts = const [];
    _invoices = const [];
    _transfers = const [];
  }

  /// Set when a write fails, so the screen can surface it rather than letting
  /// the UI silently diverge from what the server holds.
  ///
  /// IT WAS SET IN FORTY-FIVE PLACES AND SHOWN IN NONE. Every failed write in
  /// this app recorded itself here and then said nothing: the optimistic
  /// change stayed on screen, the server never heard, and the row came back on
  /// the next load. The three screens that did report a failure each checked a
  /// return value of their own; everything else — archiving a supplier, saving
  /// an item, settling a receipt, cancelling an order — failed in silence.
  ///
  /// [InventoryStatusBanner] watches it now, so a failure anywhere is visible
  /// without every caller having to remember. A screen that can say something
  /// more specific still should; this is the floor, not the ceiling.
  Object? lastWriteError;

  /// Dismisses the write-failure banner.
  ///
  /// Clearing it does not retry anything and does not make the change land —
  /// it only acknowledges the message, which is why the banner says what is
  /// still unsaved rather than offering a button that looks like a fix.
  void clearWriteError() {
    if (lastWriteError == null) return;
    lastWriteError = null;
    notifyListeners();
  }

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
    return _createItemOnServer(_api, draft);
  }

  Future<void> updateItem(String id, Item draft) async {
    return _updateItemOnServer(_api, id, draft);
  }

  Future<void> deleteItem(String id) async {
    return _deleteItemOnServer(_api, id);
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
    await _changeQuantityOnServer(_api, existing, after, kind, note);
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
      final result = await _api.adjustStock(
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
      await _refreshItem(_api, existing.id);
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

    // Billing is what takes the goods, sales order or not. The server works
    // out, for an order, which units the old despatch already sent and takes
    // only the rest.
    const movesStock = true;

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
      final saved = await _api.saveInvoice(draft);
      _invoices = [saved, ..._invoices.where((i) => i.id != saved.id)];
      if (saved.movesStock) await _refreshStockView();
      if (saved.salesOrderId != null) {
        await _refreshSalesOrder(saved.salesOrderId!);
      }
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
    // As for an invoice: the receipt is what takes the goods.
    const movesStock = true;

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
      final saved = await _api.saveReceipt(draft);
      _receipts = [saved, ..._receipts.where((r) => r.id != saved.id)];
      if (saved.movesStock) await _refreshStockView();
      if (saved.salesOrderId != null) {
        await _refreshSalesOrder(saved.salesOrderId!);
      }
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

  /// Brings receipts in from a sheet, as history rather than as sales.
  ///
  /// NOTHING MOVES IN STOCK. These are receipts that already happened —
  /// usually from the system this one is replacing — and the stock they took
  /// was taken then, by that system. Booking them out again would subtract the
  /// same goods twice and leave every count short by the whole imported
  /// history.
  ///
  /// Item names are matched where they can be, so an imported line links to
  /// the catalogue and shows in an item's history; an unmatched name stays as
  /// text, which is what the exporter wrote and what keeps the record
  /// readable either way.
  ///
  /// Returns how many landed. The ones that did not are in [failed], by
  /// reference, so the screen can name them rather than saying "some".
  Future<({int imported, List<String> failed})> importReceipts(
    List<ReceiptDraft> drafts,
  ) async {
    final byName = {
      for (final item in _items) item.name.toLowerCase().trim(): item,
    };
    final bySku = {
      for (final item in _items)
        if (item.sku.isNotEmpty) item.sku.toLowerCase().trim(): item,
    };

    var imported = 0;
    final failed = <String>[];

    for (final draft in drafts) {
      final lines = <ReceiptLine>[];
      for (final line in draft.lines) {
        final match =
            bySku[line.sku.toLowerCase().trim()] ??
            byName[line.itemName.toLowerCase().trim()];
        lines.add(
          ReceiptLine(
            id: line.id,
            itemId: match?.id ?? '',
            itemName: line.itemName,
            sku: line.sku,
            unit: line.unit,
            quantity: line.quantity,
            unitPrice: line.unitPrice,
            discount: line.discount,
            quantityRefunded: line.quantityRefunded,
            costOfGoods: line.quantity * (match?.unitCost ?? 0),
          ),
        );
      }

      final now = DateTime.now();
      final receipt = Receipt(
        id: '',
        // Blank, so the server mints one rather than this colliding with a
        // reference the workspace already used.
        reference: '',
        customerName: draft.customerName,
        method: draft.method,
        lines: lines,
        discount: draft.discount,
        taxRate: draft.taxRate.clamp(0, 1).toDouble(),
        taxLabel: draft.taxLabel,
        amountPaid: draft.amountPaid,
        notes: draft.notes,
        movesStock: false,
        issuedAt: draft.issuedAt,
        createdAt: now,
        updatedAt: now,
      );

      try {
        final saved = await _api.saveReceipt(receipt);
        _receipts = [saved, ..._receipts.where((r) => r.id != saved.id)];
        imported++;
      } catch (error) {
        failed.add(draft.reference);
        lastWriteError = error;
        debugPrint('Stockpile: could not import ${draft.reference}: $error');
      }
    }

    if (imported > 0 && failed.isEmpty) lastWriteError = null;
    notifyListeners();
    return (imported: imported, failed: failed);
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
      final saved = await _api.receiveGoods(
        order.id,
        received,
        location: _settings.locations.isEmpty
            ? 'Unassigned'
            : _settings.locations.first,
      );

      _purchaseOrders = _purchaseOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      await _refreshStockView();
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
      final saved = await _api.savePurchaseOrder(draft);
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
      final saved = await _api.despatchGoods(
        order.id,
        sent,
        location: _settings.locations.isEmpty
            ? 'Unassigned'
            : _settings.locations.first,
      );

      _salesOrders = _salesOrders
          .map((o) => o.id == saved.id ? saved : o)
          .toList();
      await _refreshStockView();
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
      final saved = await _api.saveSalesOrder(draft);
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
      final saved = await _api.refundReceipt(
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
      if (restock && saved.movesStock) await _refreshStockView();
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
      final saved = await _api.createItem(draft);
      _items = [saved, ..._items.where((i) => i.id != saved.id)];
      if (_learnOptions(saved)) {
        await _persistSettingsTo(replaceCategories: false);
      }
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
      final saved = await _api.updateItem(id, draft);
      _items = _items.map((i) => i.id == id ? saved : i).toList();
      if (_learnOptions(saved)) {
        await _persistSettingsTo(replaceCategories: false);
      }
      lastWriteError = null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the item: $error');
    }
    notifyListeners();
  }

  Future<void> _deleteItemOnServer(InventoryApi api, String id) async {
    try {
      await _api.deleteItem(id);
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

  /// Writes the picker lists back, and says whether they reached the server.
  ///
  /// Shared, these belong to the workspace rather than the device: a category
  /// somebody types on one screen has to appear in everybody else's picker.
  ///
  /// THE RETURN VALUE IS NOT DECORATION. This swallowed every failure and only
  /// printed, on the reasoning that an item save had already succeeded and the
  /// picker would catch up on the next load. That is true of the one caller it
  /// was written for and false of the other: the settings sheet adds and
  /// removes CATEGORIES through here, and a silent failure there is a category
  /// that sits on screen, never reaches the server, and is gone on the next
  /// load — reported as "the category is not saving after inputting".
  Future<bool> _persistSettingsTo({bool replaceCategories = true}) async {
    try {
      // ADD-ONLY WHEN AN ITEM TAUGHT US THE NAME. The endpoint replaces the
      // whole list, so writing this device's copy of it deletes anything
      // another device added since this one loaded — and the item path has no
      // business deleting a category at all: its entire purpose is to make
      // sure a name somebody typed into an item exists in the picker. Saving
      // an item on a tab left open all morning was enough to erase a category
      // a colleague added on theirs, with nothing on either screen to say so.
      //
      // The settings screen still replaces, because removing an entry there is
      // exactly what the user asked for.
      final names = replaceCategories
          ? _settings.categories
          : await _categoriesUnion();

      final stored = await _api.saveCategories([
        for (final name in names)
          (name: name, swatchIndex: _settings.categoryColors[name] ?? 0),
      ]);
      _adoptCategories(stored);
      await _api.saveLookupValues('location', _settings.locations);
      await _api.saveLookupValues('unit', _settings.units);
      return true;
    } catch (error) {
      debugPrint('Stockpile: could not save the picker lists: $error');
      return false;
    }
  }

  /// The server's category list with this device's additions folded in.
  ///
  /// Read first, so the write that follows can only ever add. The server's
  /// order is kept and new names go on the end, which is where the picker
  /// shows them.
  Future<List<String>> _categoriesUnion() async {
    final onServer = await _api.categories();
    final names = [for (final c in onServer) c.name];
    final known = names.toSet();
    for (final name in _settings.categories) {
      if (known.add(name)) names.add(name);
    }
    return names;
  }

  /// Takes the server's category list as the truth after a write.
  ///
  /// The server drops blank names and collapses repeats, so what it stored is
  /// not always what was sent. Keeping the sent version is how a category
  /// appears to save and then changes on the next load; this closes that gap
  /// at the moment of the write rather than one reload later.
  void _adoptCategories(List<({String name, int swatchIndex})>? stored) {
    if (stored == null) return;
    _settings = _settings.copyWith(
      categories: [for (final c in stored) c.name],
      categoryColors: {for (final c in stored) c.name: c.swatchIndex},
    );
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
      final saved = await _api.saveSupplier(payload);
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
      final saved = await _api.saveCustomer(payload);
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
    load = InventoryLoad.loading;
    loadError = null;
    notifyListeners();

    try {
      final snapshot = await loadSharedSnapshot(_api);
      // The snapshot carries no documents now, so anything fetched earlier is
      // dropped rather than left behind pointing at a workspace that may have
      // changed underneath it.
      _forgetDocuments();
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
    _forgetDocuments();
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
    final Invoice settled;
    final double taken;
    try {
      final result = await _api.payInvoice(invoice.id, amount);
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

    return _writePaymentReceipt(
      invoice,
      taken,
      method: method,
      notes: notes,
      cashier: cashier,
      paidAt: paidAt,
    );
  }

  /// Money recorded on an invoice that no receipt accounts for: a payment
  /// whose receipt failed to save. Zero when every payment has its receipt.
  double unreceiptedPayment(String invoiceId) {
    final invoice = invoiceById(invoiceId);
    if (invoice == null || invoice.status == InvoiceStatus.cancelled) return 0;
    // Only with the receipts in hand. Without them every payment looks
    // unreceipted, and issuing "the missing one" would duplicate it.
    if (!_loadedDocuments.contains(DocumentSet.receipts)) return 0;
    final receipted = paymentsForInvoice(
      invoiceId,
    ).fold(0.0, (sum, p) => sum + p.amount);
    final gap = invoice.amountPaid - receipted;
    return gap > 0.005 ? gap : 0;
  }

  /// Issues the receipt for money already recorded on an invoice whose
  /// receipt never saved. Takes no new payment. Returns null on failure.
  Future<Receipt?> issueMissingPaymentReceipt(
    String invoiceId, {
    PaymentMethod method = PaymentMethod.cash,
  }) async {
    final invoice = invoiceById(invoiceId);
    // Re-read first: another device may have issued it since this loaded.
    try {
      _receipts = await _api.receipts();
    } catch (error) {
      debugPrint('Stockpile: could not re-read receipts: $error');
      return null;
    }
    final gap = unreceiptedPayment(invoiceId);
    if (invoice == null || gap <= 0) {
      notifyListeners();
      return null;
    }
    return _writePaymentReceipt(invoice, gap, method: method);
  }

  /// The receipt for [taken] paid against [invoice].
  Future<Receipt?> _writePaymentReceipt(
    Invoice invoice,
    double taken, {
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    String cashier = '',
    DateTime? paidAt,
  }) async {
    final now = DateTime.now();

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
      final saved = await _api.saveReceipt(draft);
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

  /// Takes a party out of the pickers without erasing it.
  ///
  /// Archived rather than deleted, which is what the shared inventory
  /// supports and, on reflection, what it always meant. Documents reference
  /// suppliers and customers, and those references have to stay resolvable —
  /// an invoice whose customer has been erased is a document that can no
  /// longer say who it was for.
  ///
  /// Items linked to the supplier keep its name as free text, so the
  /// catalogue still reads properly with nothing left to click through to.
  /// Archives a supplier. Returns whether it reached the server.
  ///
  /// THE ROW USED TO GO WHATEVER HAPPENED. `_saveSupplierOnServer` catches its
  /// own failure and returns the payload it was handed, so the caller cannot
  /// tell a save from a refusal — and this then removed the supplier from the
  /// list and notified. Archiving with the server unreachable therefore took
  /// the supplier off the screen and left it untouched on the server, which is
  /// the same lie the category list used to tell: gone until the next load
  /// brings it back.
  Future<bool> archiveSupplier(String id) async {
    final supplier = supplierById(id);
    if (supplier == null) return false;

    final now = DateTime.now();
    for (final item in _items.where((i) => i.supplierId == id).toList()) {
      await _updateItemOnServer(
        _api,
        item.id,
        item.copyWith(
          supplier: supplier.name,
          clearSupplierId: true,
          updatedAt: now,
        ),
      );
    }

    await _saveSupplierOnServer(
      _api,
      Supplier(
        id: id,
        name: supplier.name,
        contactName: supplier.contactName,
        phone: supplier.phone,
        email: supplier.email,
        address: supplier.address,
        leadTimeDays: supplier.leadTimeDays,
        paymentTerms: supplier.paymentTerms,
        notes: supplier.notes,
        archived: true,
        createdAt: supplier.createdAt,
        updatedAt: now,
      ),
      id: id,
    );

    // Checked rather than assumed, because the save reports failure only here.
    if (lastWriteError != null) {
      notifyListeners();
      return false;
    }

    _suppliers = _suppliers.where((s) => s.id != id).toList();
    notifyListeners();
    return true;
  }

  /// Archives a customer. Returns whether it reached the server.
  Future<bool> archiveCustomer(String id) async {
    final customer = customerById(id);
    if (customer == null) return false;

    await _saveCustomerOnServer(
      _api,
      Customer(
        id: id,
        name: customer.name,
        contactName: customer.contactName,
        phone: customer.phone,
        email: customer.email,
        address: customer.address,
        priceTier: customer.priceTier,
        notes: customer.notes,
        archived: true,
        createdAt: customer.createdAt,
        updatedAt: DateTime.now(),
      ),
      id: id,
    );

    if (lastWriteError != null) {
      notifyListeners();
      return false;
    }

    _customers = _customers.where((c) => c.id != id).toList();
    notifyListeners();
    return true;
  }

  /// Re-reads what a document just changed.
  ///
  /// Items and movements only. Per-bin levels are read by the screens that
  /// show them, and fetching every item's breakdown here would be one request
  /// per item to populate something usually off screen.
  Future<void> _refreshStockView() async {
    try {
      // allItems, not items: the plain call stops at one page of 500, so a
      // larger catalogue lost everything past that on the first document
      // anybody raised — the same truncation the opening load had.
      final page = await _api.allItems();
      _items = page.items;
      _movements = await _api.movements(limit: maxMovements);
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
      final fresh = await _api.item(id);
      _items = _items.map((i) => i.id == id ? fresh.item : i).toList();
      _putLevels(id, fresh.stock);
    } catch (error) {
      // The conflict message still stands and is the more useful of the two.
      debugPrint('Stockpile: could not re-read $id: $error');
    }
  }

  /// Imports items from a CSV, creating each one on the server.
  ///
  /// THIS USED TO SAVE NOTHING. It put the items on this screen only, with
  /// made-up movements, and never told the server — so they were gone on the
  /// next reload, and since the screen began re-reading the server every half
  /// minute, gone within half a minute. Each item is now created like one
  /// added by hand, so its opening quantity arrives with a movement and a
  /// location, and only what the server stored is shown.
  ///
  /// A few at a time, so a long file is not one request after another, and
  /// with the background refresh held off until it is done. Returns how many
  /// were saved, how many were not, and the first reason one was refused.
  Future<({int imported, int failed, String? reason})> importDrafts(
    List<ItemDraft> drafts,
  ) async {
    if (drafts.isEmpty) return (imported: 0, failed: 0, reason: null);
    final now = DateTime.now();
    final saved = <Item>[];
    var failed = 0;
    String? reason;

    _writesInFlight++;
    try {
      const batch = 8;
      for (var start = 0; start < drafts.length; start += batch) {
        final chunk = drafts.skip(start).take(batch);
        final results = await Future.wait([
          for (final d in chunk)
            _api
                .createItem(
                  Item(
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
                .then<Item?>((item) => item)
                .catchError((Object error) {
                  failed++;
                  reason ??= reasonFor(error, 'The server refused it.');
                  debugPrint('Stockpile: could not import ${d.name}: $error');
                  return null;
                }),
        ]);
        saved.addAll(results.whereType<Item>());
      }

      if (saved.isNotEmpty) {
        final ids = {for (final i in saved) i.id};
        _items = [...saved, ..._items.where((i) => !ids.contains(i.id))];
        var learned = false;
        for (final item in saved) {
          if (_learnOptions(item)) learned = true;
        }
        // The pickers once for the whole file, not once per row.
        if (learned) await _persistSettingsTo(replaceCategories: false);
        // The items are as the server stored them already. Their opening
        // movements and locations are the server's too: re-read those.
        try {
          _movements = await _api.movements(limit: maxMovements);
          _levels = Map.of(await _api.allStock());
        } catch (error) {
          debugPrint('Stockpile: could not refresh stock after import: $error');
        }
      }
      lastWriteError = null;
    } finally {
      _writesInFlight--;
      notifyListeners();
    }
    return (imported: saved.length, failed: failed, reason: reason);
  }

  // --- Suppliers -----------------------------------------------------------

  Future<Supplier> createSupplier(Supplier draft) async {
    return _saveSupplierOnServer(_api, draft);
  }

  Future<void> updateSupplier(String id, Supplier draft) async {
    await _saveSupplierOnServer(_api, draft, id: id);

    if (supplierById(id) == null) return;
    final updated = draft.copyWith(updatedAt: DateTime.now());
    _suppliers = _suppliers.map((s) => s.id == id ? updated : s).toList()
      ..sort(_supplierOrder);
    notifyListeners();
  }

  // --- Customers -----------------------------------------------------------

  /// Imports customers from a CSV, creating each on the server. One whose
  /// name is already a customer is skipped rather than added twice. Returns
  /// how many were saved, skipped and refused, with the first refusal.
  Future<({int imported, int skipped, int failed, String? reason})>
  importCustomers(List<Customer> drafts) async {
    final known = {for (final c in _customers) c.name.trim().toLowerCase()};
    final saved = <Customer>[];
    var skipped = 0;
    var failed = 0;
    String? reason;

    _writesInFlight++;
    try {
      for (final draft in drafts) {
        final key = draft.name.trim().toLowerCase();
        if (!known.add(key)) {
          skipped++;
          continue;
        }
        try {
          // Blank id: the server assigns one, as for a customer added by hand.
          saved.add(await _api.saveCustomer(draft));
        } catch (error) {
          failed++;
          reason ??= reasonFor(error, 'The server refused it.');
          debugPrint('Stockpile: could not import ${draft.name}: $error');
        }
      }
      if (saved.isNotEmpty) {
        _customers = [
          ..._customers,
          ...saved,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }
    } finally {
      _writesInFlight--;
      notifyListeners();
    }
    return (
      imported: saved.length,
      skipped: skipped,
      failed: failed,
      reason: reason,
    );
  }

  Future<Customer> createCustomer(Customer draft) async {
    return _saveCustomerOnServer(_api, draft);
  }

  Future<void> updateCustomer(String id, Customer draft) async {
    await _saveCustomerOnServer(_api, draft, id: id);

    if (customerById(id) == null) return;
    final updated = draft.copyWith(updatedAt: DateTime.now());
    _customers = _customers.map((c) => c.id == id ? updated : c).toList()
      ..sort(_customerOrder);
    notifyListeners();
  }

  // --- Purchase orders -----------------------------------------------------

  /// The next document reference for a prefix. Counters are persisted, so a
  /// reference is never reused even after its document is deleted.
  String _nextReference(String prefix) {
    final next = (_sequences[prefix] ?? 0) + 1;
    _sequences = {..._sequences, prefix: next};
    return '$prefix-${next.toString().padLeft(4, '0')}';
  }

  Future<PurchaseOrder> createPurchaseOrder({
    String? supplierId,
    DateTime? expectedAt,
    String notes = '',
    List<PurchaseOrderLine> lines = const [],
  }) async {
    return _createPurchaseOrderOnServer(
      _api,
      supplierId: supplierId,
      expectedAt: expectedAt,
      notes: notes,
      lines: lines,
    );
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

    return _receiveOnServer(_api, order, received);
  }

  /// The purchase-order counterpart of [_replaceSalesOrder], and the same
  /// reasoning: placing and cancelling both come through here.
  void _replaceOrder(PurchaseOrder order) {
    _purchaseOrders = _purchaseOrders
        .map((o) => o.id == order.id ? order : o)
        .toList();
    notifyListeners();

    _persist(() async {
      final saved = await _api.savePurchaseOrder(order);
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
    return _createSalesOrderOnServer(
      _api,
      customerId: customerId,
      dueAt: dueAt,
      notes: notes,
      lines: lines,
    );
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
  /// Confirms the sale on the server, and says why when it is refused —
  /// chiefly when it asks for more than is in stock.
  ///
  /// Shown confirmed at once, and put back to draft if the server refuses, so
  /// a refusal is never left looking like a confirmed sale. Returns null on
  /// success, or the reason.
  Future<String?> confirmSalesOrder(String id) async {
    final existing = salesOrderById(id);
    if (existing == null ||
        existing.status != SalesStatus.draft ||
        existing.lines.isEmpty) {
      return null;
    }
    final now = DateTime.now();
    final updated = existing.copyWith(
      status: SalesStatus.confirmed,
      confirmedAt: now,
      updatedAt: now,
    );
    _salesOrders = _salesOrders.map((o) => o.id == id ? updated : o).toList();
    notifyListeners();

    try {
      final saved = await _api.saveSalesOrder(updated);
      _salesOrders = _salesOrders.map((o) => o.id == id ? saved : o).toList();
      lastWriteError = null;
      notifyListeners();
      return null;
    } catch (error) {
      _salesOrders = _salesOrders
          .map((o) => o.id == id ? existing : o)
          .toList();
      lastWriteError = error;
      debugPrint('Stockpile: could not confirm the sale: $error');
      notifyListeners();
      return reasonFor(error, 'The sale could not be confirmed.');
    }
  }

  /// The same rule the server applies to a new or draft order, so the seller
  /// is told before saving: no line may ask for more than is in stock.
  /// Returns one reason per item that is short; empty when it can go ahead.
  List<String> outOfStockReasons(List<SalesOrderLine> lines) {
    final wanted = <String, int>{};
    final names = <String, String>{};
    for (final line in lines) {
      wanted[line.itemId] = (wanted[line.itemId] ?? 0) + line.quantityOrdered;
      names[line.itemId] = line.itemName;
    }
    return [
      for (final entry in wanted.entries)
        if (entry.value > (byId(entry.key)?.quantity ?? 0))
          (byId(entry.key)?.quantity ?? 0) <= 0
              ? '${byId(entry.key)?.name ?? names[entry.key]} is out of stock '
                    '(${entry.value} ordered)'
              : '${byId(entry.key)!.name} has only '
                    '${byId(entry.key)!.quantity} in stock '
                    '(${entry.value} ordered)',
    ];
  }

  /// The message to show for a refused write: the server's own reason where
  /// it gave one.
  String reasonFor(Object? error, String fallback) =>
      error is AuthApiException ? error.message : fallback;

  /// Cancels a sale at any stage, fully sent included, and puts back the
  /// stock it sent.
  ///
  /// The server does the work: it returns the stock from the order's own
  /// despatch movements and cancels any unpaid invoice billing the order. It
  /// refuses when money has been taken against the sale. This adopts its
  /// answer and re-reads the stock rather than computing either here.
  ///
  /// Returns null on success, or the reason it was refused.
  Future<String?> cancelSalesOrder(String id, {String reason = ''}) async {
    final existing = salesOrderById(id);
    if (existing == null) return 'That sale no longer exists.';
    if (existing.status == SalesStatus.cancelled) return null;

    try {
      final result = await _api.cancelSalesOrder(id, reason: reason);
      _salesOrders = _salesOrders
          .map((o) => o.id == id ? result.order : o)
          .toList();
      final cancelled = {for (final i in result.invoices) i.id: i};
      if (cancelled.isNotEmpty) {
        _invoices = _invoices.map((i) => cancelled[i.id] ?? i).toList();
      }
      if (existing.unitsFulfilled > 0 || cancelled.isNotEmpty) {
        await _refreshStockView();
      }
      lastWriteError = null;
      notifyListeners();
      return null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not cancel the sale: $error');
      notifyListeners();
      return error is AuthApiException
          ? error.message
          : 'The sale could not be cancelled, so nothing was changed.';
    }
  }

  /// Live invoices billing a sale, for flagging one that outlived its
  /// cancelled order.
  List<Invoice> liveInvoicesForSalesOrder(String salesOrderId) => [
    for (final i in _invoices)
      if (i.salesOrderId == salesOrderId && i.status != InvoiceStatus.cancelled)
        i,
  ];

  /// Cancelled sales still needing repair. Throws on failure so the screen
  /// can say so rather than showing a clean result it never got.
  Future<List<CancelledSaleIssue>> scanCancelledSales() =>
      _api.scanCancelledSales();

  /// Finishes one cancelled sale on the server. Returns null on success, or
  /// the reason it was refused.
  Future<String?> repairCancelledSale(String salesOrderId) async {
    try {
      final result = await _api.repairCancelledSale(salesOrderId);
      _salesOrders = _salesOrders
          .map((o) => o.id == salesOrderId ? result.order : o)
          .toList();
      final cancelled = {for (final i in result.invoices) i.id: i};
      _invoices = _invoices.map((i) => cancelled[i.id] ?? i).toList();
      await _refreshStockView();
      lastWriteError = null;
      notifyListeners();
      return null;
    } catch (error) {
      debugPrint('Stockpile: could not repair the sale: $error');
      return error is AuthApiException
          ? error.message
          : 'The sale could not be repaired, so nothing was changed.';
    }
  }

  /// Repairs every fixable cancelled sale, then re-reads stock and the
  /// documents it touched.
  Future<
    ({List<String> repaired, List<({String reference, String reason})> skipped})
  >
  repairAllCancelledSales() async {
    final result = await _api.repairAllCancelledSales();
    await _refreshStockView();
    if (_loadedDocuments.contains(DocumentSet.invoices)) {
      await _fetchDocuments(DocumentSet.invoices);
    }
    if (_loadedDocuments.contains(DocumentSet.salesOrders)) {
      await _fetchDocuments(DocumentSet.salesOrders);
    }
    notifyListeners();
    return result;
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

    return _despatchOnServer(_api, order, sent);
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

    _persist(() async {
      final saved = await _api.saveSalesOrder(order);
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
      for (final (line, left) in _leftToBill(order))
        ReceiptLine(
          id: _uid(),
          itemId: line.itemId,
          itemName: line.itemName,
          sku: byId(line.itemId)?.sku ?? '',
          unit: byId(line.itemId)?.unit ?? 'pcs',
          quantity: left,
          unitPrice: line.unitPrice,
        ),
    ];
  }

  /// Each order line with what is still to be billed on it: ordered, less
  /// what live receipts and invoices for the sale already cover. A receipt
  /// for a payment on one of those invoices is not counted again.
  ///
  /// Billing is what takes the goods off the shelf, so this is also what is
  /// still to be delivered.
  List<(SalesOrderLine, int)> _leftToBill(SalesOrder order) {
    final billed = billedOnSalesOrder(order.id);
    final out = <(SalesOrderLine, int)>[];
    for (final line in order.lines) {
      final already = billed[line.itemId] ?? 0;
      // Billed quantities fill the earliest line for the item first.
      final take = already < line.quantityOrdered
          ? already
          : line.quantityOrdered;
      billed[line.itemId] = already - take;
      final left = line.quantityOrdered - take;
      if (left > 0) out.add((line, left));
    }
    return out;
  }

  /// Each order line with what is still to be billed on it.
  List<(SalesOrderLine, int)> leftToBillOn(SalesOrder order) =>
      _leftToBill(order);

  /// The stock movements a sale caused, oldest first: its old despatches,
  /// and what its receipts and invoices took or gave back. Only as far back
  /// as the movements this device has loaded.
  List<Movement> stockTakenBySale(String salesOrderId) {
    final documents = {
      salesOrderId,
      for (final r in _receipts)
        if (r.salesOrderId == salesOrderId) r.id,
      for (final i in _invoices)
        if (i.salesOrderId == salesOrderId) i.id,
    };
    final found = [
      for (final m in _movements)
        if (m.documentId != null && documents.contains(m.documentId)) m,
    ]..sort((a, b) => a.at.compareTo(b.at));
    return found;
  }

  /// Quantities already billed against a sale, per item.
  Map<String, int> billedOnSalesOrder(String salesOrderId) {
    final billed = <String, int>{};
    for (final r in _receipts) {
      if (r.salesOrderId != salesOrderId || r.invoiceId != null) continue;
      if (!r.status.countsAsSale) continue;
      for (final line in r.lines) {
        billed[line.itemId] = (billed[line.itemId] ?? 0) + line.quantity;
      }
    }
    for (final i in _invoices) {
      if (i.salesOrderId != salesOrderId || !i.status.countsAsSale) continue;
      for (final line in i.lines) {
        billed[line.itemId] = (billed[line.itemId] ?? 0) + line.quantity;
      }
    }
    return billed;
  }

  /// Units a sale's old despatch sent that no receipt or invoice has billed
  /// yet, per item. They are already off the shelf, so billing them needs no
  /// stock.
  Map<String, int> sentNotBilled(SalesOrder order) {
    final billed = billedOnSalesOrder(order.id);
    final sent = <String, int>{};
    for (final line in order.lines) {
      sent[line.itemId] = (sent[line.itemId] ?? 0) + line.quantityFulfilled;
    }
    return {
      for (final e in sent.entries)
        if (e.value - (billed[e.key] ?? 0) > 0)
          e.key: e.value - (billed[e.key] ?? 0),
    };
  }

  /// Re-reads one sales order after a document changed what it has
  /// delivered: its sent counts and status are the server's to set.
  Future<void> _refreshSalesOrder(String id) async {
    try {
      final fresh = await _api.salesOrder(id);
      _salesOrders = _salesOrders.map((o) => o.id == id ? fresh : o).toList();
    } catch (error) {
      debugPrint('Stockpile: could not refresh sales order $id: $error');
    }
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

    return _issueReceiptOnServer(
      _api,
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

    return _refundOnServer(_api, receipt, returned, restock: restock);
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

    try {
      final voided = await _api.voidReceipt(id, reason: reason);
      _receipts = _receipts.map((r) => r.id == voided.id ? voided : r).toList();
      // The server put the stock back and wrote the movement for it, so
      // the counts here are stale until re-read.
      if (voided.movesStock) await _refreshStockView();
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

  /// Records money received against a receipt that was left owing — settling
  /// an account sale. Never takes the paid figure past the total, so a
  /// receipt can not end up showing change it never gave.
  /// Takes money against an outstanding receipt. Returns what was applied.
  ///
  /// THIS NEVER LEFT THE DEVICE EITHER, and unlike the invoice cancellation it
  /// had nowhere to go: there was no endpoint at all. So a receipt left owing
  /// was marked paid on the till's own screen, the server never heard, and the
  /// next load showed it outstanding again — with the money already in the
  /// drawer.
  ///
  /// The server holds the arithmetic now, as it does for an invoice payment:
  /// it adds rather than overwrites, so two tills settling the same receipt
  /// accumulate instead of racing, and it caps the amount at the balance.
  /// Null when the write was refused.
  Future<double?> settleReceipt(
    String id,
    double amount, {
    PaymentMethod? method,
  }) async {
    final receipt = receiptById(id);
    if (receipt == null || amount <= 0 || !receipt.status.countsAsSale) {
      return null;
    }

    try {
      final result = await _api.settleReceipt(id, amount, method: method?.name);
      _receipts = _receipts
          .map((r) => r.id == id ? result.receipt : r)
          .toList();
      lastWriteError = null;
      notifyListeners();
      return result.applied;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not settle the receipt: $error');
      notifyListeners();
      return null;
    }
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

  /// Where a sale stands for money, from the receipts and invoices raised
  /// against it. A sales order holds no money itself: "paid now" is a receipt,
  /// "pay later" an invoice whose payments each become a receipt.
  ///
  /// [paid] counts receipts only. An invoice payment is a receipt carrying
  /// both the invoice and the order, so adding the invoice's own amountPaid
  /// as well would count that money twice.
  ({double paid, double owed, double unbilled, Invoice? collectable})
  paymentsForSalesOrder(String salesOrderId) {
    final order = salesOrderById(salesOrderId);
    final receipts = receiptsForSalesOrder(
      salesOrderId,
    ).where((r) => r.status.countsAsSale).toList();
    final invoices = invoicesForSalesOrder(
      salesOrderId,
    ).where((i) => i.status.countsAsSale).toList();

    var paid = 0.0;
    var owed = 0.0;
    for (final r in receipts) {
      if (r.invoiceId != null) {
        paid += r.amountPaid;
      } else {
        // A counter sale: what it came to after refunds, capped at what was
        // handed over, so change given back is not counted as income.
        paid += r.amountPaid < r.netTotal ? r.amountPaid : r.netTotal;
        owed += r.balanceDue;
      }
    }
    for (final i in invoices) {
      owed += i.balanceDue;
    }

    // What is still to be billed (and so still to be delivered), at the rate
    // a receipt or invoice from it charges.
    final leftValue = order == null
        ? 0.0
        : _leftToBill(
            order,
          ).fold(0.0, (sum, entry) => sum + entry.$2 * entry.$1.unitPrice);
    final unbilled = order?.status == SalesStatus.cancelled
        ? 0.0
        : leftValue * (1 + _settings.taxRate.clamp(0, 1));

    Invoice? collectable;
    for (final i in invoices) {
      if (i.status.isCollectable && i.balanceDue > 0) {
        collectable = i;
        break;
      }
    }

    return (
      paid: paid,
      owed: owed,
      unbilled: unbilled > 0.005 ? unbilled : 0,
      collectable: collectable,
    );
  }

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
      for (final (line, left) in _leftToBill(order))
        InvoiceLine(
          id: _uid(),
          itemId: line.itemId,
          itemName: line.itemName,
          sku: byId(line.itemId)?.sku ?? '',
          unit: byId(line.itemId)?.unit ?? 'pcs',
          quantity: left,
          unitPrice: line.unitPrice,
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

    return _issueInvoiceOnServer(
      _api,
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

    return _payInvoiceOnServer(
      _api,
      invoice,
      amount,
      method: method,
      notes: notes,
      cashier: cashier,
      paidAt: paidAt,
    );
  }

  /// Strikes an invoice off in full.
  ///
  /// Only one nothing has been paid against can be cancelled; once money has
  /// arrived the document has a history worth keeping. A cancellation puts
  /// back exactly the stock the invoice took, and nothing when it never moved
  /// any.
  ///
  /// THIS NEVER LEFT THE DEVICE. It put the stock back, wrote the movements
  /// and marked the invoice cancelled — all in memory, then notified. The
  /// server was never told, though `POST /documents/invoices/<id>/cancel` has
  /// been there the whole time and `InventoryApi.cancelInvoice` with it. So
  /// the screen showed a cancelled invoice and stock back on the shelf, and
  /// the next load showed the invoice still live and the stock still gone —
  /// having meanwhile told the user a count that was never true anywhere but
  /// on their own screen.
  ///
  /// The server owns the whole operation now, as it does for issuing one: it
  /// decides what goes back, writes the movements, and answers with the
  /// document. This adopts that answer rather than computing its own.
  Future<bool> cancelInvoice(String id, {String reason = ''}) async {
    final invoice = invoiceById(id);
    if (invoice == null ||
        invoice.status != InvoiceStatus.open ||
        invoice.amountPaid > 0) {
      return false;
    }

    try {
      final saved = await _api.cancelInvoice(id, reason: reason);
      _invoices = _invoices.map((i) => i.id == id ? saved : i).toList();
      // The stock and the movements are the server's answer too: a
      // cancellation that moved stock changed counts this device now has to
      // re-read rather than recalculate.
      // Also when it bills a cancelled sale: the server then returns that
      // sale's stock too, if it was never put back.
      final order = invoice.salesOrderId == null
          ? null
          : salesOrderById(invoice.salesOrderId!);
      if (invoice.movesStock || order?.status == SalesStatus.cancelled) {
        await _refreshStockView();
      }
      lastWriteError = null;
      notifyListeners();
      return true;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not cancel the invoice: $error');
      notifyListeners();
      return false;
    }
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
  }

  // --- Categories ----------------------------------------------------------
  //
  // THESE WRITE TO THE SERVER, and until this fix they did not. Each one
  // rebuilt `_settings` and called `notifyListeners()`, so the screen updated
  // and nothing else did — the category list is loaded from
  // `GET /inventory/categories` at startup, so a delete or a rename came back
  // on the next load. It looked like a save that did not stick; it was a save
  // that never happened. `saveCategories` existed on the API client the whole
  // time with exactly one caller: `_persistSettingsTo`, reached only when
  // saving an ITEM taught the picker a new name.
  //
  // THE WRITE IS REVERTED WHEN IT FAILS. Elsewhere in this controller a failed
  // write leaves the optimistic state on screen and reports the error —
  // reasonable when the screen is showing a value somebody typed and can retry
  // from. It is the wrong answer here: a category that vanishes from the list
  // and is still on the server reproduces the exact defect above, one reload
  // later. Better to put it back and say so.

  /// Persists the category list, and any items the change rewrote.
  ///
  /// Items carry their category by NAME, so a rename or a delete has to
  /// rewrite every item that referenced it — the server's `replaceCategories`
  /// only touches the category table. There is no bulk item endpoint, so they
  /// go one PATCH each, in bounded batches: a category with two hundred items
  /// behind it should not open two hundred simultaneous connections.
  Future<bool> _commitCategories({
    required AppSettings previousSettings,
    required List<Item> previousItems,
    required List<Item> touched,
  }) async {
    try {
      final stored = await _api.saveCategories([
        for (final name in _settings.categories)
          (name: name, swatchIndex: _settings.categoryColors[name] ?? 0),
      ]);
      _adoptCategories(stored);

      const batchSize = 8;
      for (var i = 0; i < touched.length; i += batchSize) {
        final batch = touched.skip(i).take(batchSize);
        await Future.wait([
          for (final item in batch) _api.updateItem(item.id, item),
        ]);
      }

      lastWriteError = null;
      return true;
    } catch (error) {
      // Back to exactly what was on screen before, so the list keeps agreeing
      // with the server rather than with the attempt.
      _settings = previousSettings;
      _items = previousItems;
      lastWriteError = error;
      debugPrint('Stockpile: could not save the categories: $error');
      return false;
    }
  }

  /// Adds a category. Returns whether it reached the server.
  Future<bool> addCategory(String name, int swatchIndex) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (_settings.categories.any(
      (c) => c.toLowerCase() == trimmed.toLowerCase(),
    )) {
      return false;
    }

    final previousSettings = _settings;
    _settings = _settings.copyWith(
      categories: [..._settings.categories, trimmed],
      categoryColors: {..._settings.categoryColors, trimmed: swatchIndex},
    );
    notifyListeners();

    final saved = await _commitCategories(
      previousSettings: previousSettings,
      previousItems: _items,
      touched: const [],
    );
    notifyListeners();
    return saved;
  }

  /// Renames a category and rewrites the items that referenced it, so no item
  /// is orphaned. Returns whether it reached the server.
  Future<bool> renameCategory(String from, String to, int swatchIndex) async {
    final trimmed = to.trim();
    if (trimmed.isEmpty) return false;

    final previousSettings = _settings;
    final previousItems = _items;

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

    final saved = await _commitCategories(
      previousSettings: previousSettings,
      previousItems: previousItems,
      touched: touched,
    );
    notifyListeners();
    return saved;
  }

  /// Removes the category and clears it from the items that used it, which
  /// leaves their stock untouched and marks them uncategorised. Returns
  /// whether it reached the server.
  Future<bool> deleteCategory(String name) async {
    final previousSettings = _settings;
    final previousItems = _items;

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

    final saved = await _commitCategories(
      previousSettings: previousSettings,
      previousItems: previousItems,
      touched: touched,
    );
    notifyListeners();
    return saved;
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

  /// Saves the workspace settings. Returns whether they reached the server.
  Future<bool> updateSettings(AppSettings next) async {
    _settings = next;
    notifyListeners();

    // These belong to the workspace, not the device — the company name on an
    // invoice has to be the same one everybody else prints. Written straight
    // through rather than optimistically: the screen already shows the new
    // value, and a failure is reported rather than silently reverted.
    try {
      await _api.savePreferences({
        'companyName': next.companyName,
        'currency': next.currency,
        'companyAddress': next.companyAddress,
        'companyPhone': next.companyPhone,
        'companyEmail': next.companyEmail,
        'taxRate': next.taxRate.toString(),
        'taxLabel': next.taxLabel,
        'receiptFooter': next.receiptFooter,
        // THE LOGO WAS NEVER SENT. It was set on `_settings` and shown
        // immediately, so it looked saved — and it was, in memory. Nothing
        // wrote it to the server and nothing read it back, so it survived
        // until the next load and then was simply gone.
        'companyLogo': next.companyLogo,
        'bankName': next.bankName,
        'accountName': next.accountName,
        'accountNumber': next.accountNumber,
      });
      // Reported, not printed. The categories, locations and units live here
      // as well as on their own screens, and a caller that is told nothing
      // cannot tell the user anything either.
      if (!await _persistSettingsTo()) {
        lastWriteError = StateError('The picker lists did not save.');
        notifyListeners();
        return false;
      }
      lastWriteError = null;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not save the settings: $error');
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  /// Adds the sample catalogue to the workspace, for real.
  ///
  /// IT USED TO SAVE NOTHING, AND RESET THE SETTINGS. It replaced the items
  /// on this screen with the samples and the settings with the defaults — the
  /// company name, logo and bank details included — and told the server
  /// nothing. The samples were gone on the next refresh, and any settings
  /// change made meanwhile would have saved the defaults over the real ones.
  ///
  /// Now each sample is created on the server like an import, the settings
  /// are left alone, and a sample whose name is already in the catalogue is
  /// skipped, so pressing it twice does not add everything twice.
  Future<({int imported, int failed, String? reason})> loadSampleData() {
    final existing = {for (final i in _items) i.name.trim().toLowerCase()};
    return importDrafts([
      for (final i in seedItems())
        if (!existing.contains(i.name.trim().toLowerCase()))
          ItemDraft(
            name: i.name,
            sku: i.sku,
            barcode: i.barcode,
            category: i.category,
            location: i.location,
            quantity: i.quantity,
            reorderLevel: i.reorderLevel,
            unit: i.unit,
            unitCost: i.unitCost,
            retailerPrice: i.retailerPrice,
            distributorPrice: i.distributorPrice,
            supplier: i.supplier,
            notes: i.notes,
          ),
    ]);
  }

  /// Empties the workspace's inventory.
  ///
  /// Shared, this has to reach the server or it clears the screen and nothing
  /// else: the rows come back on the next load, and they never left anybody
  /// else's. That is what it did until now.
  // --- Backup and restore --------------------------------------------------

  /// The whole workspace as JSON, ready to write to a file.
  ///
  /// Comes from the server, not from this controller: what is in memory is one
  /// page of items and whatever else has been loaded, and a backup that
  /// quietly stopped at the page boundary would restore a smaller workspace
  /// than the one it was taken from.
  Future<Map<String, dynamic>?> exportBackup() async {
    try {
      final payload = await _api.backup();
      lastWriteError = null;
      return payload;
    } catch (error) {
      lastWriteError = error;
      debugPrint('Stockpile: could not take a backup: $error');
      notifyListeners();
      return null;
    }
  }

  /// Replaces the workspace from [payload] and reloads from the server.
  ///
  /// The reload is not optional. Every screen reads this controller, and after
  /// a restore its entire contents — items, documents, stock, settings — belong
  /// to the workspace that was just replaced.
  Future<({bool ok, int rows, Object? error})> restoreBackup(
    Map<String, dynamic> payload,
  ) async {
    try {
      final written = await _api.restore(payload);
      lastWriteError = null;
      await reload();
      return (
        ok: true,
        rows: written.values.fold<int>(0, (sum, n) => sum + n),
        error: null,
      );
    } catch (error) {
      // The server restores inside one transaction, so a failure here means
      // the workspace was left exactly as it was. Nothing to undo.
      lastWriteError = error;
      debugPrint('Stockpile: could not restore the backup: $error');
      notifyListeners();
      return (ok: false, rows: 0, error: error);
    }
  }

  Future<void> eraseAll() async {
    try {
      await _api.eraseEverything();
      lastWriteError = null;
    } catch (error) {
      // Nothing is cleared locally on a failure. Showing an empty catalogue
      // the server still holds is the confusion this is meant to end.
      lastWriteError = error;
      debugPrint('Stockpile: could not erase the inventory: $error');
      notifyListeners();
      return;
    }

    // Re-read rather than reset. AppSettings() carries default categories,
    // locations and units, so assuming it here would leave the pickers showing
    // a set the server does not have — and the next save would write those
    // defaults back, undoing part of the erase.
    await reload();
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
    _writesInFlight++;
    write()
        .then((_) => lastWriteError = null)
        .catchError((Object error) {
          lastWriteError = error;
          debugPrint('Stockpile: database write failed: $error');
        })
        .whenComplete(() => _writesInFlight--);
  }

  // --- Keeping up with other devices ---------------------------------------

  /// Saves sent but not yet answered. A refresh waits for them, so it cannot
  /// replace an edit with the copy from before it.
  int _writesInFlight = 0;

  /// Bumped on every change this controller announces. A refresh that sees it
  /// move while it was fetching throws its answer away: something changed
  /// here in the meantime, and the fetched copy may predate it.
  int _changeEpoch = 0;

  bool _refreshing = false;

  /// When the last background refresh landed.
  DateTime? lastRefreshedAt;

  @override
  void notifyListeners() {
    _changeEpoch++;
    super.notifyListeners();
  }

  /// Re-reads what other people may have changed: items, stock by bin,
  /// movements, customers, suppliers, and every document list already opened.
  ///
  /// Quiet: nothing is blanked while it runs, and a failure keeps what is on
  /// screen. Skipped while a save is in flight or another refresh is running.
  /// Settings are left alone, so a form being typed into is not reset.
  Future<void> refreshFromServer() async {
    if (load != InventoryLoad.ready || _refreshing || _writesInFlight > 0) {
      return;
    }
    _refreshing = true;
    final startedAt = _changeEpoch;
    try {
      final kinds = _loadedDocuments.toSet();
      final core = await Future.wait([
        _api.allItems(),
        _api.movements(limit: maxMovements),
        _api.allStock(),
        _api.suppliers(),
        _api.customers(),
      ]);
      final docs = <DocumentSet, List<Object>>{};
      for (final kind in kinds) {
        docs[kind] = switch (kind) {
          DocumentSet.invoices => await _api.invoices(),
          DocumentSet.receipts => await _api.receipts(),
          DocumentSet.purchaseOrders => await _api.purchaseOrders(),
          DocumentSet.salesOrders => await _api.salesOrders(),
          DocumentSet.transfers => await _api.transfers(),
        };
      }

      if (_changeEpoch != startedAt || _writesInFlight > 0) return;

      final page = core[0] as ({List<Item> items, int total});
      _items = page.items;
      _movements = (core[1] as List).cast();
      _levels = Map.of((core[2] as Map).cast<String, Map<String, int>>());
      _suppliers = (core[3] as List).cast();
      _customers = (core[4] as List).cast();
      for (final entry in docs.entries) {
        switch (entry.key) {
          case DocumentSet.invoices:
            _invoices = entry.value.cast();
          case DocumentSet.receipts:
            _receipts = entry.value.cast();
          case DocumentSet.purchaseOrders:
            _purchaseOrders = entry.value.cast();
          case DocumentSet.salesOrders:
            _salesOrders = entry.value.cast();
          case DocumentSet.transfers:
            _transfers = entry.value.cast();
        }
      }
      lastRefreshedAt = DateTime.now();
      notifyListeners();
    } catch (error) {
      debugPrint('Stockpile: background refresh failed: $error');
    } finally {
      _refreshing = false;
    }
  }

  String _uid() => _ids.next();
}
