import '../models/item.dart';
import '../models/movement.dart';
import '../models/party.dart';
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
  Future<Item> updateItem(Item draft) async {
    final payload = _itemPayload(draft)..remove('quantity');
    final body = await _auth.send(
      'PATCH',
      '/inventory/items/${draft.id}',
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
  // Workspace settings
  // ------------------------------------------------------------------

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
