import '../models/item.dart';
import '../models/movement.dart';
import '../models/invoice.dart';
import '../models/party.dart';
import '../models/purchase_order.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../models/transfer.dart';
import 'document_parsing.dart';
import 'auth_api.dart';

/// The shared inventory, over HTTP.
///
/// Until now every device kept its own SQLite copy, which is why the same
/// account showed different stock on the web and on a phone. This reads the
/// one on the server instead.
///
/// It borrows [AuthApi.send] rather than opening its own connection, so there
/// is a single token pipeline: refresh, the 401 retry and revocation all
/// behave here exactly as they do for the account screens.
class InventoryApi {
  const InventoryApi(this._auth);

  final AuthApi _auth;

  /// Empties the inventory on the server.
  ///
  /// Accounts, roles and the audit trail are left alone — clearing the stock
  /// is not asking to be signed out, and the record of who did what includes
  /// this.
  Future<void> eraseEverything() => _auth.send('DELETE', '/inventory');

  // ------------------------------------------------------------------
  // Items
  // ------------------------------------------------------------------

  Future<({List<Item> items, int total})> items({
    String? search,
    String? category,
    String? location,
    String? supplierId,
    bool lowStockOnly = false,
    int limit = 500,
    int offset = 0,
  }) async {
    final query = <String, String>{
      if (search != null && search.isNotEmpty) 'search': search,
      if (category != null && category.isNotEmpty) 'category': category,
      if (location != null && location.isNotEmpty) 'location': location,
      if (supplierId != null && supplierId.isNotEmpty) 'supplier': supplierId,
      if (lowStockOnly) 'low': 'true',
      'limit': '$limit',
      'offset': '$offset',
    };
    final body = await _auth.send('GET', '/inventory/items${_query(query)}');
    return (
      items: _list(body['items']).map(Item.fromJson).toList(),
      total: (body['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// One item with the per-bin breakdown the stock screen needs.
  Future<({Item item, Map<String, int> stock})> item(String id) async {
    final body = await _auth.send('GET', '/inventory/items/$id');
    return (
      item: Item.fromJson(body['item'] as Map<String, dynamic>),
      stock: {
        for (final row in _list(body['stock']))
          row['location'] as String: (row['quantity'] as num).toInt(),
      },
    );
  }

  Future<Item> createItem(Item draft) async {
    final body = await _auth.send(
      'POST',
      '/inventory/items',
      body: _itemPayload(draft),
    );
    return Item.fromJson(body['item'] as Map<String, dynamic>);
  }

  /// Sends only the fields the server accepts through this path.
  ///
  /// Quantity is deliberately not among them: the server refuses to move a
  /// count except through an adjustment, so that every change carries a
  /// movement explaining it. Sending it here would be silently ignored, which
  /// is worse than not sending it.
  /// [id] is passed rather than read off [draft], because the editor builds a
  /// draft from the form and has no reason to carry the id around in it.
  Future<Item> updateItem(String id, Item draft) async {
    final payload = _itemPayload(draft)
      ..remove('quantity')
      ..remove('id');
    final body = await _auth.send(
      'PATCH',
      '/inventory/items/$id',
      body: payload,
    );
    return Item.fromJson(body['item'] as Map<String, dynamic>);
  }

  Future<void> deleteItem(String id) =>
      _auth.send('DELETE', '/inventory/items/$id');

  // ------------------------------------------------------------------
  // Stock
  // ------------------------------------------------------------------

  /// Moves a count and records why, in one server-side transaction.
  ///
  /// [expectedQuantity] is the count this device believed was current. When it
  /// no longer matches the server, the write is refused with
  /// [StockConflictException] rather than applied — two people counting the
  /// same shelf must not silently overwrite each other.
  Future<({Item item, Movement movement})> adjustStock({
    required String itemId,
    required int delta,
    required int expectedQuantity,
    String kind = 'adjustment',
    String location = 'Unassigned',
    String note = '',
    String? documentId,
  }) async {
    try {
      final body = await _auth.send(
        'POST',
        '/inventory/stock/adjust',
        body: {
          'itemId': itemId,
          'delta': delta,
          'expectedQuantity': expectedQuantity,
          'kind': kind,
          'location': location,
          'note': note,
          'documentId': ?documentId,
        },
      );
      return (
        item: Item.fromJson(body['item'] as Map<String, dynamic>),
        movement: Movement.fromJson(body['movement'] as Map<String, dynamic>),
      );
    } on AuthApiException catch (error) {
      if (error.code == 'stock_conflict') {
        throw StockConflictException(error.message);
      }
      rethrow;
    }
  }

  Future<List<Movement>> transferStock({
    required String fromLocation,
    required String toLocation,
    required List<({String itemId, int quantity})> lines,
    String reference = '',
    String note = '',
  }) async {
    final body = await _auth.send(
      'POST',
      '/inventory/stock/transfer',
      body: {
        'fromLocation': fromLocation,
        'toLocation': toLocation,
        'reference': reference,
        'note': note,
        'lines': [
          for (final line in lines)
            {'itemId': line.itemId, 'quantity': line.quantity},
        ],
      },
    );
    return _list(body['movements']).map(Movement.fromJson).toList();
  }

  /// Every bin at once, keyed item id -> location -> quantity.
  ///
  /// One request rather than one per item: the initial load needs the whole
  /// picture, and asking per item would be a request for every row in the
  /// catalogue before the first screen could paint.
  Future<Map<String, Map<String, int>>> allStock() async {
    final body = await _auth.send('GET', '/inventory/stock');
    final levels = <String, Map<String, int>>{};
    for (final row in _list(body['stock'])) {
      final itemId = row['itemId'] as String;
      levels.putIfAbsent(itemId, () => <String, int>{})[row['location']
          as String] = (row['quantity'] as num)
          .toInt();
    }
    return levels;
  }

  // ------------------------------------------------------------------
  // History
  // ------------------------------------------------------------------

  Future<List<Movement>> movements({
    String? itemId,
    int limit = 500,
    int offset = 0,
  }) async {
    final query = <String, String>{
      if (itemId != null && itemId.isNotEmpty) 'item': itemId,
      'limit': '$limit',
      'offset': '$offset',
    };
    final body = await _auth.send(
      'GET',
      '/inventory/movements${_query(query)}',
    );
    return _list(body['movements']).map(Movement.fromJson).toList();
  }

  // ------------------------------------------------------------------
  // Parties
  // ------------------------------------------------------------------

  Future<List<Supplier>> suppliers({bool includeArchived = false}) async {
    final body = await _auth.send(
      'GET',
      '/inventory/suppliers${includeArchived ? '?archived=true' : ''}',
    );
    return _list(body['suppliers']).map(supplierFromJson).toList();
  }

  Future<Supplier> saveSupplier(Supplier supplier) async {
    final body = await _auth.send(
      'POST',
      '/inventory/suppliers',
      body: supplier.toJson(),
    );
    return supplierFromJson(body['supplier'] as Map<String, dynamic>);
  }

  Future<List<Customer>> customers({bool includeArchived = false}) async {
    final body = await _auth.send(
      'GET',
      '/inventory/customers${includeArchived ? '?archived=true' : ''}',
    );
    return _list(body['customers']).map(customerFromJson).toList();
  }

  Future<Customer> saveCustomer(Customer customer) async {
    final body = await _auth.send(
      'POST',
      '/inventory/customers',
      body: customer.toJson(),
    );
    return customerFromJson(body['customer'] as Map<String, dynamic>);
  }

  // ------------------------------------------------------------------
  // Documents
  //
  // Invoices and receipts move stock server-side, so these do not send
  // quantities of their own — the lines are the instruction, and the server
  // works out and records the effect.
  // ------------------------------------------------------------------

  Future<List<Invoice>> invoices({String? status}) async {
    final body = await _auth.send(
      'GET',
      '/documents/invoices${_status(status)}',
    );
    return _list(body['invoices']).map(invoiceFromJson).toList();
  }

  Future<Invoice> saveInvoice(Invoice invoice) async {
    final existing = invoice.id.isNotEmpty;
    final body = await _auth.send(
      existing ? 'PATCH' : 'POST',
      existing ? '/documents/invoices/${invoice.id}' : '/documents/invoices',
      body: invoice.toJson(),
    );
    return invoiceFromJson(body['invoice'] as Map<String, dynamic>);
  }

  /// Cancelled, never deleted: an invoice that was issued is a thing that
  /// happened, and the stock it moved comes back through a movement rather
  /// than by the original quietly disappearing.
  Future<Invoice> cancelInvoice(String id, {String reason = ''}) async {
    final body = await _auth.send(
      'POST',
      '/documents/invoices/$id/cancel',
      body: {'reason': reason},
    );
    return invoiceFromJson(body['invoice'] as Map<String, dynamic>);
  }

  /// Records money taken against an invoice.
  ///
  /// The server adds to the running total rather than being told what it is,
  /// so two tills settling the same invoice accumulate instead of overwriting
  /// each other. It also caps the amount at the balance — [applied] is what
  /// was actually taken, and the difference is the customer's change.
  Future<({Invoice invoice, double applied})> payInvoice(
    String id,
    double amount,
  ) async {
    final body = await _auth.send(
      'POST',
      '/documents/invoices/$id/payments',
      body: {'amount': amount},
    );
    return (
      invoice: invoiceFromJson(body['invoice'] as Map<String, dynamic>),
      applied: (body['applied'] as num?)?.toDouble() ?? 0,
    );
  }

  Future<List<Receipt>> receipts({String? status}) async {
    final body = await _auth.send(
      'GET',
      '/documents/receipts${_status(status)}',
    );
    return _list(body['receipts']).map(receiptFromJson).toList();
  }

  Future<Receipt> saveReceipt(Receipt receipt) async {
    final body = await _auth.send(
      'POST',
      '/documents/receipts',
      body: receipt.toJson(),
    );
    return receiptFromJson(body['receipt'] as Map<String, dynamic>);
  }

  /// Takes goods back against a receipt.
  ///
  /// [restock] is why this is not simply the sale in reverse: goods that come
  /// back saleable go on the shelf, goods that come back broken do not, and
  /// the money is refunded either way.
  Future<Receipt> refundReceipt(
    String id,
    Map<String, int> returnedByLineId, {
    bool restock = true,
    String location = 'Unassigned',
  }) async {
    final body = await _auth.send(
      'POST',
      '/documents/receipts/$id/refund',
      body: {
        'returned': returnedByLineId,
        'restock': restock,
        'location': location,
      },
    );
    return receiptFromJson(body['receipt'] as Map<String, dynamic>);
  }

  Future<Receipt> voidReceipt(String id, {String reason = ''}) async {
    final body = await _auth.send(
      'POST',
      '/documents/receipts/$id/void',
      body: {'reason': reason},
    );
    return receiptFromJson(body['receipt'] as Map<String, dynamic>);
  }

  Future<List<PurchaseOrder>> purchaseOrders({String? status}) async {
    final body = await _auth.send(
      'GET',
      '/documents/purchase-orders${_status(status)}',
    );
    return _list(body['purchaseOrders']).map(purchaseOrderFromJson).toList();
  }

  Future<PurchaseOrder> savePurchaseOrder(PurchaseOrder order) async {
    final existing = order.id.isNotEmpty;
    final body = await _auth.send(
      existing ? 'PATCH' : 'POST',
      existing
          ? '/documents/purchase-orders/${order.id}'
          : '/documents/purchase-orders',
      body: order.toJson(),
    );
    return purchaseOrderFromJson(body['purchaseOrder'] as Map<String, dynamic>);
  }

  /// Receiving is what moves stock, not ordering. Partial deliveries are the
  /// normal case, so this says what actually turned up per line.
  Future<PurchaseOrder> receiveGoods(
    String orderId,
    Map<String, int> receivedByLineId, {
    String location = 'Unassigned',
  }) async {
    final body = await _auth.send(
      'POST',
      '/documents/purchase-orders/$orderId/receive',
      body: {'received': receivedByLineId, 'location': location},
    );
    return purchaseOrderFromJson(body['purchaseOrder'] as Map<String, dynamic>);
  }

  Future<List<SalesOrder>> salesOrders({String? status}) async {
    final body = await _auth.send(
      'GET',
      '/documents/sales-orders${_status(status)}',
    );
    return _list(body['salesOrders']).map(salesOrderFromJson).toList();
  }

  Future<SalesOrder> saveSalesOrder(SalesOrder order) async {
    final existing = order.id.isNotEmpty;
    final body = await _auth.send(
      existing ? 'PATCH' : 'POST',
      existing
          ? '/documents/sales-orders/${order.id}'
          : '/documents/sales-orders',
      body: order.toJson(),
    );
    return salesOrderFromJson(body['salesOrder'] as Map<String, dynamic>);
  }

  /// Despatching is what moves stock, not confirming the order. Each line is
  /// clamped by the server to what is still outstanding *and* what is on the
  /// shelf, so what comes back may be less than was sent.
  Future<SalesOrder> despatchGoods(
    String orderId,
    Map<String, int> sentByLineId, {
    String location = 'Unassigned',
  }) async {
    final body = await _auth.send(
      'POST',
      '/documents/sales-orders/$orderId/despatch',
      body: {'sent': sentByLineId, 'location': location},
    );
    return salesOrderFromJson(body['salesOrder'] as Map<String, dynamic>);
  }

  Future<List<Transfer>> transfers() async {
    final body = await _auth.send('GET', '/documents/transfers');
    return _list(body['transfers']).map(transferFromJson).toList();
  }

  String _status(String? status) =>
      status == null || status.isEmpty ? '' : '?status=$status';

  // ------------------------------------------------------------------
  // Categories and pickers
  // ------------------------------------------------------------------

  Future<List<({String name, int swatchIndex})>> categories() async {
    final body = await _auth.send('GET', '/inventory/categories');
    return [
      for (final row in _list(body['categories']))
        (
          name: row['name'] as String? ?? '',
          swatchIndex: (row['swatchIndex'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// Writes the category list and returns what the server now holds.
  ///
  /// The response is the authoritative list, and the caller is expected to
  /// adopt it rather than keep the list it sent: the server drops blanks and
  /// collapses repeats, so the two are not always the same, and a screen that
  /// keeps its own version is how a category appears to save and then comes
  /// back changed on the next load.
  /// Null when the response carried no list at all, which is not the same as
  /// an empty one: deleting the last category legitimately returns none, and
  /// adopting `[]` from a reply that simply did not mention categories would
  /// erase the list rather than mirror it.
  Future<List<({String name, int swatchIndex})>?> saveCategories(
    List<({String name, int swatchIndex})> categories,
  ) async {
    final body = await _auth.send(
      'PUT',
      '/inventory/categories',
      body: {
        'categories': [
          for (final c in categories)
            {'name': c.name, 'swatchIndex': c.swatchIndex},
        ],
      },
    );
    if (body['categories'] is! List) return null;
    return [
      for (final row in _list(body['categories']))
        (
          name: row['name'] as String? ?? '',
          swatchIndex: (row['swatchIndex'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// One picker list — locations, units — in the order the workspace set.
  Future<List<String>> lookupValues(String kind) async {
    final body = await _auth.send('GET', '/inventory/lookups?kind=$kind');
    return [
      for (final row in _list(body['lookups'])) row['value'] as String? ?? '',
    ]..removeWhere((value) => value.isEmpty);
  }

  Future<void> saveLookupValues(String kind, List<String> values) =>
      _auth.send('PUT', '/inventory/lookups/$kind', body: {'values': values});

  // ------------------------------------------------------------------
  // Workspace settings
  // ------------------------------------------------------------------

  // ------------------------------------------------------------------
  // Backup and restore
  // ------------------------------------------------------------------

  /// The whole workspace, as the server holds it.
  ///
  /// Taken server-side rather than assembled from what this device has
  /// loaded: the item list is fetched one page at a time, so a backup built
  /// from memory would quietly stop at whatever the last page was.
  Future<Map<String, dynamic>> backup() =>
      _auth.send('GET', '/inventory/backup');

  /// Replaces the workspace with [payload]. Returns what was written, by
  /// table, so the screen can say more than "done".
  Future<Map<String, int>> restore(Map<String, dynamic> payload) async {
    final body = await _auth.send('POST', '/inventory/restore', body: payload);
    final restored = body['restored'];
    if (restored is! Map) return const {};
    return {
      for (final entry in restored.entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };
  }

  Future<Map<String, String>> preferences() async {
    final body = await _auth.send('GET', '/inventory/preferences');
    final raw = body['preferences'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  /// Merged, not replaced: a screen saves the keys it owns and must not blank
  /// the ones another screen wrote.
  Future<Map<String, String>> savePreferences(
    Map<String, String> values,
  ) async {
    final body = await _auth.send(
      'PATCH',
      '/inventory/preferences',
      body: {'preferences': values},
    );
    final raw = body['preferences'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  // ------------------------------------------------------------------

  /// The item as the API expects it.
  ///
  /// Built from the model's own toJson so the two cannot drift, minus the
  /// fields the server owns: it stamps created and updated itself, and will
  /// not take either from a client whose clock it has no reason to trust.
  Map<String, dynamic> _itemPayload(Item item) {
    final payload = item.toJson()
      ..remove('createdAt')
      ..remove('updatedAt');
    return payload;
  }

  String _query(Map<String, String> parameters) {
    if (parameters.isEmpty) return '';
    return '?${Uri(queryParameters: parameters).query}';
  }

  List<Map<String, dynamic>> _list(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map) entry.cast<String, dynamic>(),
    ];
  }
}

/// Somebody else moved this stock while the user was working.
///
/// Its own type rather than a generic failure because the screen has to say
/// something specific: retrying blindly would apply the change against a count
/// the user never saw.
class StockConflictException implements Exception {
  const StockConflictException(this.message);

  final String message;

  @override
  String toString() => message;
}

// --------------------------------------------------------------------
// Party parsing
//
// Supplier and Customer carry toJson but never needed the other direction
// while they only ever came out of drift.
// --------------------------------------------------------------------

Supplier supplierFromJson(Map<String, dynamic> json) {
  final now = DateTime.now();
  return Supplier(
    id: _str(json['id']),
    name: _str(json['name']),
    contactName: _str(json['contactName']),
    phone: _str(json['phone']),
    email: _str(json['email']),
    address: _str(json['address']),
    leadTimeDays: _int(json['leadTimeDays']),
    paymentTerms: _str(json['paymentTerms']),
    notes: _str(json['notes']),
    archived: json['archived'] == true,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

Customer customerFromJson(Map<String, dynamic> json) {
  final now = DateTime.now();
  return Customer(
    id: _str(json['id']),
    name: _str(json['name']),
    contactName: _str(json['contactName']),
    phone: _str(json['phone']),
    email: _str(json['email']),
    address: _str(json['address']),
    priceTier: priceTierFrom(json['priceTier'] as String?),
    notes: _str(json['notes']),
    archived: json['archived'] == true,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

String _str(Object? value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

int _int(Object? value) => value is num ? value.toInt() : 0;

/// Parsed as UTC and returned local. The server always sends the trailing `Z`;
/// a bare string would otherwise be read as local time and land on the wrong
/// instant for anyone outside the server's zone.
DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}
