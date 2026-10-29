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

  /// Makes the next write fail, so a test can check what the app does when a
  /// save does not land — which is where the quiet bugs live.
  bool failNextWrite = false;

  /// Paths whose next GET should fail, so a test can check what the app does
  /// when a fetch does not land. Documents are fetched on demand now, and a
  /// collection that failed has to be retried rather than left looking empty
  /// for the rest of the session.
  final failNextReadOf = <String>{};

  /// What the workspace's preferences hold, so a test can stage what a load
  /// should bring back.
  Map<String, String> preferences = const {};

  /// The last preferences written, so a test can assert that a setting
  /// actually LEFT — the company logo looked saved for months because nobody
  /// checked this.
  Map<String, dynamic>? lastPreferences;

  /// Sales orders as last echoed, so a cancel can answer with the order.
  final _salesOrders = <String, Map<String, dynamic>>{};

  String _id(Map<String, dynamic> body, String fallbackPrefix) {
    final sent = body['id'];
    if (sent is String && sent.isNotEmpty) return sent;
    return '$fallbackPrefix${_nextId++}';
  }

  http.Client client() => MockClient((request) async {
    final route = '${request.method} ${request.url.path}';
    calls.add(route);

    if (failNextWrite && request.method != 'GET') {
      failNextWrite = false;
      return http.Response(
        jsonEncode({
          'error': {'code': 'internal_error', 'message': 'Nope.'},
        }),
        500,
        headers: {'content-type': 'application/json'},
      );
    }
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
      if (failNextReadOf.remove(path)) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'internal_error', 'message': 'Nope.'},
          }),
          500,
          headers: {'content-type': 'application/json'},
        );
      }
      return _ok(switch (path) {
        '/api/inventory/items' => {'items': <Object?>[], 'total': 0},
        '/api/inventory/stock' => {'stock': <Object?>[]},
        '/api/inventory/movements' => {'movements': <Object?>[]},
        '/api/inventory/suppliers' => {'suppliers': <Object?>[]},
        '/api/inventory/customers' => {'customers': <Object?>[]},
        '/api/inventory/categories' => {'categories': <Object?>[]},
        '/api/inventory/lookups' => {'lookups': <Object?>[]},
        '/api/inventory/preferences' => {'preferences': preferences},
        '/api/documents/invoices' => {'invoices': <Object?>[]},
        '/api/documents/receipts' => {'receipts': <Object?>[]},
        '/api/documents/purchase-orders' => {'purchaseOrders': <Object?>[]},
        '/api/documents/sales-orders' => {'salesOrders': <Object?>[]},
        '/api/documents/transfers' => {'transfers': <Object?>[]},
        _ => <String, Object?>{},
      });
    }

    if (request.method == 'DELETE') return http.Response('', 204);

    if (request.method == 'PATCH' && path == '/api/inventory/preferences') {
      final sent = (body['preferences'] as Map?)?.cast<String, dynamic>() ?? {};
      lastPreferences = sent;
      preferences = {
        ...preferences,
        for (final e in sent.entries) e.key: '${e.value ?? ''}',
      };
      return _ok({'preferences': preferences});
    }

    // The category write answers with what it stored, as the real route does.
    // Anything less makes a client that adopts the reply look broken here and
    // work in production, which is the wrong way round for a test double.
    if (request.method == 'PUT' && path == '/api/inventory/categories') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final seen = <String>{};
      return _ok({
        'categories': [
          for (final raw in (body['categories'] as List? ?? const []))
            if (raw is Map)
              if (((raw['name'] as String?) ?? '').trim() case final name
                  when name.isNotEmpty && seen.add(name))
                {
                  'name': name,
                  'swatchIndex': (raw['swatchIndex'] as num?)?.toInt() ?? 0,
                },
        ],
      });
    }

    // A well-formed answer, not a computed one: the count that comes back is
    // whatever was sent. A test asserting on the resulting quantity is
    // asserting the server's arithmetic and belongs in the server suite; what
    // is left here is that the screen made the call and responded to it.
    if (path == '/api/inventory/stock/adjust') {
      final itemId = body['itemId'] as String? ?? 'i1';
      final delta = (body['delta'] as num?)?.toInt() ?? 0;
      final before = (body['expectedQuantity'] as num?)?.toInt() ?? 0;
      return _ok({
        'item': {
          'id': itemId,
          'name': 'Item',
          'quantity': before + delta,
          'unit': 'pcs',
          'createdAt': '2026-09-16T10:00:00.000Z',
          'updatedAt': '2026-09-16T10:00:00.000Z',
        },
        'movement': {
          'id': 'm-fake',
          'itemId': itemId,
          'itemName': 'Item',
          'kind': body['kind'] ?? 'adjustment',
          'before': before,
          'after': before + delta,
          'note': body['note'] ?? '',
          'actor': 'test',
          'documentId': null,
          'at': '2026-09-16T10:00:00.000Z',
        },
      });
    }

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
    // Settling a receipt. Thin like the rest of this fake: it answers with
    // what it was told, capped at nothing, because the capping-at-the-balance
    // arithmetic is the server's and is tested there. What a client test can
    // usefully assert here is that the write LEFT, and that the answer was
    // adopted rather than recomputed.
    if (path.startsWith('/api/documents/receipts/') &&
        path.endsWith('/payments')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final amount = (body['amount'] as num?)?.toDouble() ?? 0;
      final id = path.split('/')[4];
      return _ok({
        'receipt': {
          'id': id,
          'reference': 'RC-0001',
          'amountPaid': amount,
          'lines': <Object?>[],
          'issuedAt': DateTime.now().toIso8601String(),
          'createdAt': DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
        },
        'applied': amount,
      });
    }

    if (path == '/api/documents/purchase-orders') {
      return _ok(echo('purchaseOrder', 'po-', {'reference': 'PO-0001'}));
    }
    if (path == '/api/documents/sales-orders') {
      final answer = echo('salesOrder', 'so-', {'reference': 'SO-0001'});
      final order = answer['salesOrder'] as Map<String, dynamic>;
      _salesOrders[order['id'] as String] = order;
      return _ok(answer);
    }
    // Cancelling answers with the order marked cancelled. What stock comes
    // back is the server's arithmetic and is tested there.
    if (path.startsWith('/api/documents/sales-orders/') &&
        path.endsWith('/cancel')) {
      final id = path.split('/')[4];
      return _ok({
        'salesOrder': {...?_salesOrders[id], 'id': id, 'status': 'cancelled'},
        'invoices': <Object?>[],
      });
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
