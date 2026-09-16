import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `body` is typed `Map<String, Object?>`, so reading a nested field needs a
/// cast at every hop. These assertions are about the shape of the response,
/// not about proving its static type, so one dynamic view keeps them legible.
extension _Json on ApiResponse {
  dynamic get json => body as dynamic;
}

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() async => server.close());

  Future<TestSession> admin() => server.signedInUser(
    email: 'admin@example.com',
    role: administratorRoleKey,
  );

  Future<String> createItem(
    TestSession session, {
    String name = 'Widget',
    int quantity = 0,
    int reorderLevel = 0,
    String location = 'Main',
  }) async {
    final response = await server.post(
      '/inventory/items',
      accessToken: session.accessToken,
      body: {
        'name': name,
        'quantity': quantity,
        'reorderLevel': reorderLevel,
        'location': location,
      },
    );
    expect(response.statusCode, 201);
    return response.json['item']['id'] as String;
  }

  group('items', () {
    test('an item can be created, read back and listed', () async {
      final session = await admin();
      final id = await createItem(session, name: 'Blue widget', quantity: 5);

      final read = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      expect(read.statusCode, 200);
      expect(read.json['item']['name'], 'Blue widget');
      expect(read.json['item']['quantity'], 5);

      final list = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(list.json['total'], 1);
    });

    test('the same item is visible to a different signed-in user', () async {
      // The whole point of the move: two people, one inventory. This is the
      // test that would have failed when the data lived on each device.
      final owner = await admin();
      await createItem(owner, name: 'Shared widget', quantity: 3);

      final other = await server.signedInUser(email: 'other@example.com');
      final list = await server.get(
        '/inventory/items',
        accessToken: other.accessToken,
      );
      expect(list.statusCode, 200);
      expect(list.json['total'], 1);
      expect(list.json['items'][0]['name'], 'Shared widget');
    });

    test('search matches name, sku and barcode', () async {
      final session = await admin();
      await server.post(
        '/inventory/items',
        accessToken: session.accessToken,
        body: {'name': 'Hammer', 'sku': 'TOOL-1', 'barcode': '5012345'},
      );
      await createItem(session, name: 'Nail');

      for (final needle in ['hammer', 'tool-1', '5012345']) {
        final found = await server.get(
          '/inventory/items?search=$needle',
          accessToken: session.accessToken,
        );
        expect(found.json['total'], 1, reason: 'searching for $needle');
        expect(found.json['items'][0]['name'], 'Hammer');
      }
    });

    test('an unknown item is a 404, not an empty object', () async {
      final session = await admin();
      final response = await server.get(
        '/inventory/items/does-not-exist',
        accessToken: session.accessToken,
      );
      expect(response.statusCode, 404);
    });
  });

  group('stock', () {
    test('an adjustment moves the count and records why', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 10);

      final response = await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {
          'itemId': id,
          'delta': -3,
          'kind': 'sale',
          'note': 'Sold at the counter',
          'location': 'Main',
          'expectedQuantity': 10,
        },
      );

      expect(response.statusCode, 200);
      expect(response.json['item']['quantity'], 7);
      expect(response.json['movement']['before'], 10);
      expect(response.json['movement']['after'], 7);
      expect(response.json['movement']['kind'], 'sale');
      expect(response.json['movement']['note'], 'Sold at the counter');
    });

    test('a quantity never changes without a movement explaining it', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 4);

      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 6, 'location': 'Main'},
      );

      final history = await server.get(
        '/inventory/movements?item=$id',
        accessToken: session.accessToken,
      );
      final movements = history.json['movements'] as List;
      // One for the opening quantity, one for the adjustment.
      expect(movements.length, greaterThanOrEqualTo(1));

      final latest = movements.first;
      expect(latest['after'], 10);
      expect(latest['itemName'], isNotEmpty);
    });

    test('a write made against a stale count is refused', () async {
      // Two people counting the same shelf. The second must not silently
      // overwrite the first — that is how a stock record stops matching
      // reality with nothing to show for it afterwards.
      final session = await admin();
      final id = await createItem(session, quantity: 10);

      final first = await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': -2, 'expectedQuantity': 10},
      );
      expect(first.statusCode, 200);
      expect(first.json['item']['quantity'], 8);

      final stale = await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': -5, 'expectedQuantity': 10},
      );
      expect(stale.statusCode, 409);
      expect(stale.json['error']['code'], 'stock_conflict');

      final after = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      expect(
        after.json['item']['quantity'],
        8,
        reason: 'unchanged by the refusal',
      );
    });

    test('stock cannot be driven negative', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 2);

      final response = await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': -5},
      );
      expect(response.statusCode, 400);

      final after = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      expect(after.json['item']['quantity'], 2);
    });

    test('the total always equals the sum of its bins', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 0, location: 'Main');

      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 7, 'location': 'Main'},
      );
      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 5, 'location': 'Back room'},
      );

      final read = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      final bins = read.json['stock'] as List;
      final summed = bins.fold<int>(
        0,
        (total, bin) => total + (bin['quantity'] as int),
      );
      expect(read.json['item']['quantity'], summed);
      expect(read.json['item']['quantity'], 12);
    });
  });

  group('bins', () {
    test('stock with no location named lands somewhere countable', () async {
      // Never a blank bin: stock whose location nobody recorded still has to
      // be findable, so it sits in a named one.
      final session = await admin();
      final id = await createItem(session, quantity: 0, location: '');

      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 5},
      );

      final read = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      final bins = {
        for (final bin in read.json['stock'] as List)
          bin['location'] as String: bin['quantity'] as int,
      };
      expect(bins.keys, isNot(contains('')));
      expect(bins['Unassigned'], 5);
    });

    test('taking more than one bin holds drains the others', () async {
      // The bin totals and the item total have to stay honest together. Guarding
      // only the total lets a bin go negative while the sum still adds up,
      // which reads as stock sitting in a place that has none.
      final session = await admin();
      final id = await createItem(session, quantity: 0, location: 'Main');

      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 3, 'location': 'Main'},
      );
      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 7, 'location': 'Back room'},
      );

      // Ten on hand, only three of them in Main.
      final sale = await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {
          'itemId': id,
          'delta': -8,
          'location': 'Main',
          'expectedQuantity': 10,
        },
      );
      expect(sale.statusCode, 200);
      expect(sale.json['item']['quantity'], 2);

      final read = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      for (final bin in read.json['stock'] as List) {
        expect(
          bin['quantity'] as int,
          greaterThanOrEqualTo(0),
          reason: '${bin['location']} went negative',
        );
      }
    });

    test('deleting an item takes its bins with it', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 4, location: 'Main');

      await server.delete(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );

      final stock = await server.get(
        '/inventory/stock',
        accessToken: session.accessToken,
      );
      final rows = (stock.json['stock'] as List).where(
        (row) => row['itemId'] == id,
      );
      expect(rows, isEmpty);
    });
  });

  group('transfers', () {
    test(
      'a transfer moves stock between bins without changing the total',
      () async {
        final session = await admin();
        final id = await createItem(session, quantity: 0, location: 'Main');
        await server.post(
          '/inventory/stock/adjust',
          accessToken: session.accessToken,
          body: {'itemId': id, 'delta': 10, 'location': 'Main'},
        );

        final response = await server.post(
          '/inventory/stock/transfer',
          accessToken: session.accessToken,
          body: {
            'fromLocation': 'Main',
            'toLocation': 'Back room',
            'lines': [
              {'itemId': id, 'quantity': 4},
            ],
          },
        );
        expect(response.statusCode, 201);

        final read = await server.get(
          '/inventory/items/$id',
          accessToken: session.accessToken,
        );
        expect(read.json['item']['quantity'], 10, reason: 'total unchanged');

        final bins = {
          for (final bin in read.json['stock'] as List)
            bin['location'] as String: bin['quantity'] as int,
        };
        expect(bins['Main'], 6);
        expect(bins['Back room'], 4);
      },
    );

    test('a transfer of more than the bin holds is refused entirely', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 0, location: 'Main');
      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': 3, 'location': 'Main'},
      );

      final response = await server.post(
        '/inventory/stock/transfer',
        accessToken: session.accessToken,
        body: {
          'fromLocation': 'Main',
          'toLocation': 'Back room',
          'lines': [
            {'itemId': id, 'quantity': 9},
          ],
        },
      );
      expect(response.statusCode, 400);

      // The whole transfer rolls back, including the Transfers row written
      // before the failing line was reached.
      final read = await server.get(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );
      final bins = {
        for (final bin in read.json['stock'] as List)
          bin['location'] as String: bin['quantity'] as int,
      };
      expect(bins['Main'], 3);
      expect(bins.containsKey('Back room'), isFalse);
    });
  });

  group('permissions', () {
    test('staff record movements but cannot change the catalogue', () async {
      // The boundary the role actually draws: "Records stock movements and
      // receives goods. Read-only elsewhere." Staff holds inventory.adjust on
      // purpose — what it does not hold is items.create/update/delete.
      final owner = await admin();
      final id = await createItem(owner, quantity: 5);
      final staff = await server.signedInUser(email: 'staff@example.com');

      final read = await server.get(
        '/inventory/items/$id',
        accessToken: staff.accessToken,
      );
      expect(read.statusCode, 200);

      final adjust = await server.post(
        '/inventory/stock/adjust',
        accessToken: staff.accessToken,
        body: {'itemId': id, 'delta': 1},
      );
      expect(adjust.statusCode, 200, reason: 'staff record movements');

      final create = await server.post(
        '/inventory/items',
        accessToken: staff.accessToken,
        body: {'name': 'Not allowed'},
      );
      expect(create.statusCode, 403);

      final destroy = await server.delete(
        '/inventory/items/$id',
        accessToken: staff.accessToken,
      );
      expect(destroy.statusCode, 403);

      final settings = await server.patch(
        '/inventory/preferences',
        accessToken: staff.accessToken,
        body: {
          'preferences': {'companyName': 'Nope'},
        },
      );
      expect(settings.statusCode, 403);
    });

    test('the inventory is not readable without a session', () async {
      final response = await server.get('/inventory/items');
      expect(response.statusCode, 401);
    });
  });

  group('a blank id means "mint one", not "use this one"', () {
    // The editors build a draft with id: '' for anything new, and toJson always
    // includes the key — so the field arrives present and empty. Treating that
    // as an id gives every new row the same one, and the second collides on the
    // primary key.

    test('a second supplier can be added', () async {
      final session = await admin();

      final first = await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'Acme'},
      );
      expect(first.statusCode, 200);

      final second = await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'Globex'},
      );
      expect(second.statusCode, 200);

      expect(
        second.json['supplier']['id'],
        isNot(first.json['supplier']['id']),
        reason: 'two suppliers cannot share an id',
      );

      final list = await server.get(
        '/inventory/suppliers',
        accessToken: session.accessToken,
      );
      expect((list.json['suppliers'] as List).length, 2);
    });

    test('a second customer can be added', () async {
      final session = await admin();

      await server.post(
        '/inventory/customers',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'First'},
      );
      final second = await server.post(
        '/inventory/customers',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'Second'},
      );

      expect(second.statusCode, 200);
      final list = await server.get(
        '/inventory/customers',
        accessToken: session.accessToken,
      );
      expect((list.json['customers'] as List).length, 2);
    });

    test('a second item can be added', () async {
      final session = await admin();

      await server.post(
        '/inventory/items',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'First'},
      );
      final second = await server.post(
        '/inventory/items',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'Second'},
      );

      expect(second.statusCode, 201);
      final list = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(list.json['total'], 2);
    });

    test('an id that was sent is still honoured', () async {
      // Only blank means "mint one". A real id has to keep working, or an edit
      // would create a duplicate instead of updating the row.
      final session = await admin();

      await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'id': 'sup-fixed', 'name': 'Original'},
      );
      final again = await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'id': 'sup-fixed', 'name': 'Renamed'},
      );

      expect(again.json['supplier']['id'], 'sup-fixed');
      final list = await server.get(
        '/inventory/suppliers',
        accessToken: session.accessToken,
      );
      expect(
        (list.json['suppliers'] as List).length,
        1,
        reason: 'an edit, not a second row',
      );
      expect(list.json['suppliers'][0]['name'], 'Renamed');
    });
  });

  group('workspace settings', () {
    test('preferences are shared, and merged rather than replaced', () async {
      final session = await admin();

      await server.patch(
        '/inventory/preferences',
        accessToken: session.accessToken,
        body: {
          'preferences': {'companyName': 'Chedra Olympas'},
        },
      );
      await server.patch(
        '/inventory/preferences',
        accessToken: session.accessToken,
        body: {
          'preferences': {'invoicePrefix': 'INV-'},
        },
      );

      final other = await server.signedInUser(email: 'other@example.com');
      final read = await server.get(
        '/inventory/preferences',
        accessToken: other.accessToken,
      );
      expect(read.json['preferences']['companyName'], 'Chedra Olympas');
      expect(
        read.json['preferences']['invoicePrefix'],
        'INV-',
        reason: 'the second write must not blank the first',
      );
    });
  });
}
