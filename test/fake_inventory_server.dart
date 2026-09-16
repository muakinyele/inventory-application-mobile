import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/inventory_api.dart';
import 'package:stockpile/data/token_storage.dart';

/// A stand-in for the API that stores what it is given and hands it back.
///
/// Deliberately thin. It does not compute stock, allocate references or clamp
/// anything — all of that lives on the real server and is tested there,
/// against a real database. A second implementation of it here would be a
/// second thing to keep in step, and the whole reason this session found ten
/// defects is that two implementations had quietly stopped agreeing.
///
/// What it is for: the handful of tests whose subject is something the client
/// still owns — pickers learning a new category, a list staying sorted, a
/// screen rendering what it was handed — but which reach it through a write.
/// Those need the write to succeed, not to be correct arithmetic.
///
/// A test that asserts on a quantity after an adjustment does not belong here.
/// It belongs on the server, where the arithmetic is.
class FakeInventoryServer {
  final calls = <String>[];
  int _nextId = 1;

  String _id(Map<String, dynamic> body, String fallbackPrefix) {
    final sent = body['id'];
    if (sent is String && sent.isNotEmpty) return sent;
    return '$fallbackPrefix${_nextId++}';
  }

  http.Client client() => MockClient((request) async {
    final route = '${request.method} ${request.url.path}';
    calls.add(route);
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    Map<String, dynamic> echo(String key, String prefix, [Object? extra]) => {
      key: {
        ...body,
        'id': _id(body, prefix),
        if (extra != null) ...(extra as Map<String, dynamic>),
      },
    };

    final path = request.url.path;

    // Reads: empty, because a seeded controller already holds its state and a
    // reload is not what these tests are about.
    if (request.method == 'GET') {
      return _ok(switch (path) {
        '/api/inventory/items' => {'items': <Object?>[], 'total': 0},
        '/api/inventory/stock' => {'stock': <Object?>[]},
        '/api/inventory/movements' => {'movements': <Object?>[]},
        '/api/inventory/suppliers' => {'suppliers': <Object?>[]},
        '/api/inventory/customers' => {'customers': <Object?>[]},
        '/api/inventory/categories' => {'categories': <Object?>[]},
        '/api/inventory/lookups' => {'lookups': <Object?>[]},
        '/api/inventory/preferences' => {'preferences': <String, String>{}},
        '/api/documents/invoices' => {'invoices': <Object?>[]},
        '/api/documents/receipts' => {'receipts': <Object?>[]},
        '/api/documents/purchase-orders' => {'purchaseOrders': <Object?>[]},
        '/api/documents/sales-orders' => {'salesOrders': <Object?>[]},
        '/api/documents/transfers' => {'transfers': <Object?>[]},
        _ => <String, Object?>{},
      });
    }

    if (request.method == 'DELETE') return http.Response('', 204);

    if (path == '/api/inventory/items') return _ok(echo('item', 'item-'));
    if (path.startsWith('/api/inventory/items/')) {
      return _ok({
        'item': {...body, 'id': path.split('/').last},
      });
    }
    if (path == '/api/inventory/suppliers') {
      return _ok(echo('supplier', 'sup-'));
    }
    if (path == '/api/inventory/customers') {
      return _ok(echo('customer', 'cus-'));
    }
    if (path == '/api/documents/invoices') {
      return _ok(echo('invoice', 'inv-', {'reference': 'INV-0001'}));
    }
    if (path == '/api/documents/receipts') {
      return _ok(echo('receipt', 'rcp-', {'reference': 'RC-0001'}));
    }
    if (path == '/api/documents/purchase-orders') {
      return _ok(echo('purchaseOrder', 'po-', {'reference': 'PO-0001'}));
    }
    if (path == '/api/documents/sales-orders') {
      return _ok(echo('salesOrder', 'so-', {'reference': 'SO-0001'}));
    }

    return _ok(const <String, Object?>{});
  });

  http.Response _ok(Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// An [InventoryApi] over [FakeInventoryServer], with a live session.
Future<InventoryApi> fakeInventoryApi(FakeInventoryServer server) async {
  final storage = InMemoryTokenStorage();
  await storage.write(
    StoredTokens(
      accessToken: 'test-access',
      refreshToken: 'test-refresh',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    ),
  );
  final auth = AuthApi(
    baseUrl: 'https://test.invalid/api',
    storage: storage,
    client: server.client(),
  );
  await auth.restore();
  return InventoryApi(auth);
}
