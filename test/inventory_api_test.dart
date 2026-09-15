import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/inventory_api.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/models/item.dart';

/// Records what the client sent and answers with whatever the test needs, so
/// these assert the wire contract rather than re-testing the server.
class _Fake {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  final authHeaders = <String?>[];

  Map<String, dynamic> Function(Map<String, dynamic> body)? respond;
  int status = 200;
  Map<String, dynamic>? error;

  http.Client client() => MockClient((request) async {
    calls.add(
      '${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}',
    );
    authHeaders.add(request.headers['authorization']);
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    bodies.add(body);

    if (error != null) {
      return http.Response(
        jsonEncode({'error': error}),
        status,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(respond?.call(body) ?? <String, dynamic>{}),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
}

Map<String, dynamic> _item({
  String id = 'i1',
  String name = 'Widget',
  int quantity = 5,
}) => {
  'id': id,
  'name': name,
  'sku': 'SKU-1',
  'barcode': '',
  'category': 'Tools',
  'location': 'Main',
  'quantity': quantity,
  'reorderLevel': 2,
  'unit': 'pcs',
  'unitCost': 1.5,
  'retailerPrice': 3.0,
  'distributorPrice': 2.5,
  'supplier': '',
  'supplierId': null,
  'unitsPerPack': 1,
  'notes': '',
  'photo': null,
  'createdAt': '2026-09-01T10:00:00.000Z',
  'updatedAt': '2026-09-02T10:00:00.000Z',
};

void main() {
  late _Fake fake;
  late InventoryApi api;

  setUp(() async {
    fake = _Fake();
    final storage = InMemoryTokenStorage();
    await storage.write(
      StoredTokens(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      ),
    );
    final auth = AuthApi(
      baseUrl: 'https://example.test/api',
      storage: storage,
      client: fake.client(),
    );
    await auth.restore();
    api = InventoryApi(auth);
  });

  group('items', () {
    test('a listing is parsed into models', () async {
      fake.respond = (_) => {
        'items': [_item(), _item(id: 'i2', name: 'Hammer')],
        'total': 2,
      };

      final page = await api.items();

      expect(page.total, 2);
      expect(page.items.map((i) => i.name), ['Widget', 'Hammer']);
      expect(page.items.first.quantity, 5);
      expect(page.items.first.unitCost, 1.5);
      expect(fake.calls.single, startsWith('GET /api/inventory/items'));
    });

    test('filters travel as query parameters, not a body', () async {
      fake.respond = (_) => {'items': <Object?>[], 'total': 0};

      await api.items(search: 'ham mer', category: 'Tools', lowStockOnly: true);

      final call = fake.calls.single;
      expect(call, contains('search=ham+mer'));
      expect(call, contains('category=Tools'));
      expect(call, contains('low=true'));
    });

    test('the request carries the session token', () async {
      fake.respond = (_) => {'items': <Object?>[], 'total': 0};
      await api.items();
      expect(fake.authHeaders.single, 'Bearer access-1');
    });

    test('an update never sends quantity', () async {
      // The server moves a count only through an adjustment, so that every
      // change carries a movement explaining it. Sending quantity here would
      // be silently dropped, which is worse than not sending it.
      fake.respond = (_) => {'item': _item()};

      await api.updateItem(Item.fromJson(_item(quantity: 99)));

      expect(fake.bodies.single.containsKey('quantity'), isFalse);
      expect(fake.bodies.single['name'], 'Widget');
    });

    test('created and updated timestamps are the server\'s to set', () async {
      fake.respond = (body) => {'item': _item()};

      await api.createItem(Item.fromJson(_item()));

      expect(fake.bodies.single.containsKey('createdAt'), isFalse);
      expect(fake.bodies.single.containsKey('updatedAt'), isFalse);
    });

    test('an item is read back with its per-bin breakdown', () async {
      fake.respond = (_) => {
        'item': _item(quantity: 12),
        'stock': [
          {'itemId': 'i1', 'location': 'Main', 'quantity': 7},
          {'itemId': 'i1', 'location': 'Back room', 'quantity': 5},
        ],
      };

      final result = await api.item('i1');

      expect(result.item.quantity, 12);
      expect(result.stock, {'Main': 7, 'Back room': 5});
      expect(
        result.stock.values.reduce((a, b) => a + b),
        result.item.quantity,
        reason: 'the bins must account for the total',
      );
    });
  });

  group('stock', () {
    test('an adjustment sends the count it was made against', () async {
      fake.respond = (_) => {
        'item': _item(quantity: 3),
        'movement': {
          'id': 'm1',
          'itemId': 'i1',
          'itemName': 'Widget',
          'kind': 'sale',
          'before': 5,
          'after': 3,
          'note': '',
          'actor': 'u1',
          'documentId': null,
          'at': '2026-09-15T10:00:00.000Z',
        },
      };

      final result = await api.adjustStock(
        itemId: 'i1',
        delta: -2,
        expectedQuantity: 5,
        kind: 'sale',
      );

      expect(fake.bodies.single['expectedQuantity'], 5);
      expect(fake.bodies.single['delta'], -2);
      expect(result.item.quantity, 3);
      expect(result.movement.before, 5);
      expect(result.movement.after, 3);
    });

    test('a stale count surfaces as its own exception', () async {
      // Not a generic failure: the screen has to say something specific,
      // because retrying blindly would apply the change against a count the
      // user never saw.
      fake.status = 409;
      fake.error = {
        'code': 'stock_conflict',
        'message': 'This item now reads 8, not 10.',
      };

      expect(
        () => api.adjustStock(itemId: 'i1', delta: -5, expectedQuantity: 10),
        throwsA(
          isA<StockConflictException>().having(
            (e) => e.message,
            'message',
            contains('now reads 8'),
          ),
        ),
      );
    });

    test('other failures are not disguised as conflicts', () async {
      fake.status = 403;
      fake.error = {'code': 'forbidden', 'message': 'Not allowed.'};

      expect(
        () => api.adjustStock(itemId: 'i1', delta: 1, expectedQuantity: 0),
        throwsA(isA<AuthApiException>()),
      );
    });
  });

  group('timestamps', () {
    test('a UTC instant from the server is not shifted by the local zone', () {
      // The server always sends the trailing Z. Parsed without it, a device in
      // another zone would land on a different instant.
      final item = Item.fromJson(_item());
      expect(item.createdAt.toUtc().hour, 10);
      expect(item.createdAt.toUtc().day, 1);
    });
  });

  group('preferences', () {
    test('saving merges rather than replacing', () async {
      fake.respond = (body) => {
        'preferences': {'companyName': 'Chedra', 'invoicePrefix': 'INV-'},
      };

      final saved = await api.savePreferences({'invoicePrefix': 'INV-'});

      expect(fake.bodies.single['preferences'], {'invoicePrefix': 'INV-'});
      expect(saved['companyName'], 'Chedra', reason: 'kept by the server');
      expect(saved['invoicePrefix'], 'INV-');
    });
  });
}
