import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/inventory_api.dart';
import 'package:stockpile/data/inventory_loader.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/models/app_settings.dart';

class _Fake {
  final calls = <String>[];
  bool failItems = false;

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    calls.add(path);

    if (failItems && path.endsWith('/inventory/items')) {
      return http.Response(
        jsonEncode({
          'error': {'code': 'server_error', 'message': 'Database unreachable.'},
        }),
        500,
        headers: {'content-type': 'application/json'},
      );
    }

    final body = switch (path) {
      '/api/inventory/items' => {
        'items': [
          {
            'id': 'i1',
            'name': 'Widget',
            'quantity': 7,
            'location': 'Main',
            'unit': 'pcs',
            'createdAt': '2026-09-01T10:00:00.000Z',
            'updatedAt': '2026-09-01T10:00:00.000Z',
          },
        ],
        'total': 1,
      },
      '/api/inventory/stock' => {
        'stock': [
          {'itemId': 'i1', 'location': 'Main', 'quantity': 4},
          {'itemId': 'i1', 'location': 'Back room', 'quantity': 3},
        ],
      },
      '/api/inventory/preferences' => {
        'preferences': {
          'companyName': 'Chedra Olympas',
          'currency': 'NGN',
          'taxRate': '0.075',
          'taxLabel': 'VAT',
        },
      },
      '/api/inventory/categories' => {
        'categories': [
          {'name': 'Tools', 'swatchIndex': 2, 'position': 0},
        ],
      },
      '/api/inventory/lookups' => {
        'lookups': [
          {'kind': 'location', 'value': 'Main', 'position': 0},
          {'kind': 'location', 'value': 'Back room', 'position': 1},
        ],
      },
      '/api/inventory/movements' => {'movements': <Object?>[]},
      '/api/inventory/suppliers' => {'suppliers': <Object?>[]},
      '/api/inventory/customers' => {'customers': <Object?>[]},
      '/api/documents/invoices' => {'invoices': <Object?>[]},
      '/api/documents/receipts' => {'receipts': <Object?>[]},
      '/api/documents/purchase-orders' => {'purchaseOrders': <Object?>[]},
      '/api/documents/sales-orders' => {'salesOrders': <Object?>[]},
      '/api/documents/transfers' => {'transfers': <Object?>[]},
      _ => <String, Object?>{},
    };

    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<InventoryApi> _api(_Fake fake) async {
  final storage = InMemoryTokenStorage();
  await storage.write(
    StoredTokens(
      accessToken: 'a',
      refreshToken: 'r',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    ),
  );
  final auth = AuthApi(
    baseUrl: 'https://example.test/api',
    storage: storage,
    client: fake.client(),
  );
  await auth.restore();
  return InventoryApi(auth);
}

void main() {
  test('the opening snapshot comes from the server', () async {
    final fake = _Fake();
    final snapshot = await loadSharedSnapshot(await _api(fake));

    expect(snapshot.items.single.name, 'Widget');
    expect(snapshot.items.single.quantity, 7);
    expect(snapshot.levels['i1'], {'Main': 4, 'Back room': 3});
    expect(snapshot.settings.companyName, 'Chedra Olympas');
    expect(snapshot.settings.taxRate, 0.075);
    expect(snapshot.settings.categories, ['Tools']);
    expect(snapshot.settings.categoryColors['Tools'], 2);
    expect(snapshot.settings.locations, ['Main', 'Back room']);
  });

  test('every list is fetched, not just the ones a screen needs', () async {
    final fake = _Fake();
    await loadSharedSnapshot(await _api(fake));

    for (final path in [
      '/api/inventory/items',
      '/api/inventory/movements',
      '/api/inventory/stock',
      '/api/inventory/suppliers',
      '/api/inventory/customers',
      '/api/documents/invoices',
      '/api/documents/receipts',
      '/api/documents/purchase-orders',
      '/api/documents/sales-orders',
      '/api/documents/transfers',
    ]) {
      expect(fake.calls, contains(path), reason: '$path was not requested');
    }
  });

  test('a failure is raised, not smoothed into an empty inventory', () async {
    // Online-only: there is no local copy to fall back on, so starting with an
    // empty catalogue would look exactly like a workspace with nothing in it.
    // That is the one thing this must never be mistaken for.
    final fake = _Fake()..failItems = true;
    final api = await _api(fake);

    expect(
      () => loadSharedSnapshot(api),
      throwsA(isA<AuthApiException>()),
    );
  });

  test('document references are the server\'s to allocate', () async {
    // Sequences stay empty on purpose: the server allocates each reference
    // inside the transaction that writes the document, so a client-side
    // counter could only ever be a stale second opinion.
    final snapshot = await loadSharedSnapshot(await _api(_Fake()));
    expect(snapshot.sequences, isEmpty);
  });

  test('missing preferences fall back to the same defaults as before', () {
    // The screens have always been able to open a workspace that has never
    // been configured, and moving the data must not change that.
    const defaults = AppSettings();
    expect(defaults.companyName, isNotEmpty);
    expect(defaults.locations, isNotEmpty);
  });
}
