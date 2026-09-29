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

    test('deleting an item keeps its history', () async {
      // The movements carry the item's name, so the ledger stays readable
      // after the row is gone. Deleting them would erase the record of stock
      // that genuinely moved.
      final session = await admin();
      final id = await createItem(session, quantity: 5, location: 'Main');
      await server.post(
        '/inventory/stock/adjust',
        accessToken: session.accessToken,
        body: {'itemId': id, 'delta': -2, 'note': 'Sold one'},
      );

      await server.delete(
        '/inventory/items/$id',
        accessToken: session.accessToken,
      );

      final history = await server.get(
        '/inventory/movements?item=$id',
        accessToken: session.accessToken,
      );
      final movements = history.json['movements'] as List;
      expect(movements, isNotEmpty, reason: 'the ledger outlives the item');
      expect(movements.first['itemName'], isNotEmpty);
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

  group('erasing', () {
    test('it empties the inventory and everything hanging off it', () async {
      final session = await admin();
      final id = await createItem(session, quantity: 10, location: 'Main');
      await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'id': '', 'name': 'Acme'},
      );
      await server.post(
        '/documents/invoices',
        accessToken: session.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );

      final response = await server.delete(
        '/inventory',
        accessToken: session.accessToken,
      );
      expect(response.statusCode, 204);

      final items = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(items.json['total'], 0);

      final stock = await server.get(
        '/inventory/stock',
        accessToken: session.accessToken,
      );
      expect(stock.json['stock'], isEmpty);

      final movements = await server.get(
        '/inventory/movements',
        accessToken: session.accessToken,
      );
      expect(movements.json['movements'], isEmpty);

      final suppliers = await server.get(
        '/inventory/suppliers',
        accessToken: session.accessToken,
      );
      expect(suppliers.json['suppliers'], isEmpty);

      final invoices = await server.get(
        '/documents/invoices',
        accessToken: session.accessToken,
      );
      expect(invoices.json['invoices'], isEmpty);
    });

    test('a row with a blank id goes with the rest', () async {
      // The reason this came up. Rows created before the blank-id fix carry
      // id '', which no screen can open and no delete can name — the URL for
      // one is /items/ and matches nothing. Erasing has to reach them.
      final session = await admin();
      await server.customStatement(
        "INSERT INTO items (id, name, sku, barcode, category, location, "
        "quantity, reorder_level, unit, unit_cost, retailer_price, "
        "distributor_price, supplier, units_per_pack, notes, created_at, "
        // Epoch milliseconds: drift stores a DateTime as bigint here, not as
        // a timestamp, so `now()` is the wrong type.
        "updated_at) VALUES ('', 'Orphan', '', '', '', '', 0, 0, 'pcs', 0, 0, "
        "0, '', 1, '', 1758000000000, 1758000000000)",
      );

      final before = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(before.json['total'], 1);

      await server.delete('/inventory', accessToken: session.accessToken);

      final after = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(after.json['total'], 0);
    });

    test('it clears the categories and pickers too', () async {
      final session = await admin();
      await server.put(
        '/inventory/categories',
        accessToken: session.accessToken,
        body: {
          'categories': [
            {'name': 'Tools', 'swatchIndex': 2},
            {'name': 'Fixings', 'swatchIndex': 5},
          ],
        },
      );
      await server.put(
        '/inventory/lookups/location',
        accessToken: session.accessToken,
        body: {
          'values': ['Main', 'Van'],
        },
      );

      final before = await server.get(
        '/inventory/categories',
        accessToken: session.accessToken,
      );
      expect((before.json['categories'] as List).length, 2);

      await server.delete('/inventory', accessToken: session.accessToken);

      final after = await server.get(
        '/inventory/categories',
        accessToken: session.accessToken,
      );
      expect(after.json['categories'], isEmpty);

      final lookups = await server.get(
        '/inventory/lookups?kind=location',
        accessToken: session.accessToken,
      );
      expect(lookups.json['lookups'], isEmpty);
    });

    test('it leaves the accounts alone', () async {
      // Clearing the stock is not asking to be signed out, and the audit trail
      // is the record of who did what — including this.
      final session = await admin();
      await server.delete('/inventory', accessToken: session.accessToken);

      final me = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(me.statusCode, 200, reason: 'still signed in');
    });

    test('staff cannot erase the workspace', () async {
      final staff = await server.signedInUser(email: 'staff@example.com');
      final response = await server.delete(
        '/inventory',
        accessToken: staff.accessToken,
      );
      expect(response.statusCode, 403);
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

  // ------------------------------------------------------------------
  // Categories
  //
  // The list is REPLACED by each write and the name is the primary key, so
  // the payload has to be a set before it reaches the insert. Both ways it
  // could fail to be one were reachable from the app, and both surfaced to
  // the user as the same thing: a category that would not save.
  // ------------------------------------------------------------------
  group('categories', () {
    test(
      'a repeated name is collapsed rather than failing the write',
      () async {
        // Renaming one category onto another's name sends the same name twice.
        // That used to fail the batch insert outright — a 500 the app reported
        // as "the category could not be saved", for a payload naming only
        // categories the workspace already had.
        final session = await admin();

        final response = await server.put(
          '/inventory/categories',
          accessToken: session.accessToken,
          body: {
            'categories': [
              {'name': 'Parts', 'swatchIndex': 1},
              {'name': 'Parts', 'swatchIndex': 4},
            ],
          },
        );

        expect(response.statusCode, 200);
        final stored = response.json['categories'] as List;
        expect(stored, hasLength(1));
        expect(
          (stored.single as Map)['swatchIndex'],
          1,
          reason: 'the first occurrence wins, so the order sent is kept',
        );
      },
    );

    test('a blank name is dropped rather than stored', () async {
      // A nameless category is a blank row in the list with no way to select,
      // rename or delete it.
      final session = await admin();

      await server.put(
        '/inventory/categories',
        accessToken: session.accessToken,
        body: {
          'categories': [
            {'name': 'Parts', 'swatchIndex': 1},
            {'name': '   ', 'swatchIndex': 0},
          ],
        },
      );

      final read = await server.get(
        '/inventory/categories',
        accessToken: session.accessToken,
      );
      final stored = read.json['categories'] as List;
      expect(stored, hasLength(1));
      expect((stored.single as Map)['name'], 'Parts');
    });

    test('names are trimmed, and positions close the gaps', () async {
      final session = await admin();

      final response = await server.put(
        '/inventory/categories',
        accessToken: session.accessToken,
        body: {
          'categories': [
            {'name': '  Parts  ', 'swatchIndex': 1},
            {'name': '', 'swatchIndex': 0},
            {'name': 'Tools', 'swatchIndex': 2},
          ],
        },
      );

      final stored = response.json['categories'] as List;
      expect([for (final c in stored) (c as Map)['name']], ['Parts', 'Tools']);
      expect(
        [for (final c in stored) (c as Map)['position']],
        [0, 1],
        reason: 'a dropped entry must not leave a hole in the order',
      );
    });

    test('the write answers with the list it stored', () async {
      // The client adopts this reply rather than keeping what it sent, which
      // is what stops a category appearing to save and then changing on the
      // next load.
      final session = await admin();

      final response = await server.put(
        '/inventory/categories',
        accessToken: session.accessToken,
        body: {
          'categories': [
            {'name': 'Drinks', 'swatchIndex': 3},
          ],
        },
      );

      final read = await server.get(
        '/inventory/categories',
        accessToken: session.accessToken,
      );
      expect(response.json['categories'], equals(read.json['categories']));
    });

    test('staff cannot change the categories', () async {
      final staff = await server.signedInUser(email: 'hand@example.com');

      final response = await server.put(
        '/inventory/categories',
        accessToken: staff.accessToken,
        body: {
          'categories': [
            {'name': 'Parts', 'swatchIndex': 1},
          ],
        },
      );

      expect(response.statusCode, 403);
    });
  });

  // ------------------------------------------------------------------
  // Backup and restore
  //
  // The promise is that a restored workspace IS the one that was backed up.
  // Every test here checks that against the API the app actually reads, not
  // against the row count.
  // ------------------------------------------------------------------
  group('backup and restore', () {
    /// A workspace with something in every corner of it.
    Future<void> seed(TestSession session) async {
      await server.put(
        '/inventory/categories',
        accessToken: session.accessToken,
        body: {
          'categories': [
            {'name': 'Parts', 'swatchIndex': 2},
          ],
        },
      );
      await server.patch(
        '/inventory/preferences',
        accessToken: session.accessToken,
        body: {
          'preferences': {'companyName': 'Chedra Olympas'},
        },
      );
      final supplier = await server.post(
        '/inventory/suppliers',
        accessToken: session.accessToken,
        body: {'name': 'Acme', 'email': 'acme@example.com'},
      );
      final itemId = await createItem(
        session,
        name: 'Bolt',
        quantity: 12,
        location: 'Main',
      );
      await server.patch(
        '/inventory/items/$itemId',
        accessToken: session.accessToken,
        body: {
          'category': 'Parts',
          'supplierId': supplier.json['supplier']['id'],
        },
      );
    }

    test('a backup carries every table, not just the visible ones', () async {
      final session = await admin();
      await seed(session);

      final backup = await server.get(
        '/inventory/backup',
        accessToken: session.accessToken,
      );

      expect(backup.statusCode, 200);
      expect(backup.json['version'], 1);
      final tables = backup.json['tables'] as Map;
      // The four the old client-side backup carried, and the ones it did not.
      for (final name in [
        'items',
        'movements',
        'receipts',
        'preferences',
        'suppliers',
        'customers',
        'categories',
        'lookups',
        'stockLevels',
        'purchaseOrders',
        'salesOrders',
        'invoices',
        'transfers',
      ]) {
        expect(tables.containsKey(name), isTrue, reason: '\$name is missing');
      }
      expect((tables['items'] as List), hasLength(1));
      expect((tables['suppliers'] as List), hasLength(1));
      expect(
        (tables['stockLevels'] as List),
        isNotEmpty,
        reason: 'where the stock actually sits',
      );
    });

    test('restoring puts the workspace back as it was', () async {
      final session = await admin();
      await seed(session);

      final backup = await server.get(
        '/inventory/backup',
        accessToken: session.accessToken,
      );
      final before = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      final stockBefore = await server.get(
        '/inventory/stock',
        accessToken: session.accessToken,
      );

      // Somebody empties it, then changes their mind.
      await server.delete('/inventory', accessToken: session.accessToken);
      final emptied = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(emptied.json['total'], 0);

      final restore = await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: backup.json,
      );
      expect(restore.statusCode, 200);

      final after = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(after.json['items'], equals(before.json['items']));

      final stockAfter = await server.get(
        '/inventory/stock',
        accessToken: session.accessToken,
      );
      expect(
        stockAfter.json['stock'],
        equals(stockBefore.json['stock']),
        reason: 'stock must come back where it was, not as a fresh count',
      );

      final categories = await server.get(
        '/inventory/categories',
        accessToken: session.accessToken,
      );
      expect((categories.json['categories'] as List).single['name'], 'Parts');

      final prefs = await server.get(
        '/inventory/preferences',
        accessToken: session.accessToken,
      );
      expect(prefs.json['preferences']['companyName'], 'Chedra Olympas');

      final suppliers = await server.get(
        '/inventory/suppliers',
        accessToken: session.accessToken,
      );
      expect((suppliers.json['suppliers'] as List), hasLength(1));
    });

    test('restoring replaces rather than merges', () async {
      // Otherwise a restore doubles everything it is given.
      final session = await admin();
      await seed(session);
      final backup = await server.get(
        '/inventory/backup',
        accessToken: session.accessToken,
      );

      await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: backup.json,
      );

      final items = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(items.json['total'], 1, reason: 'restored onto itself, not twice');
    });

    test('a failed restore leaves the workspace untouched', () async {
      // The whole point of doing it in one transaction: a restore that
      // cleared first and then failed would leave nothing at all.
      final session = await admin();
      await seed(session);

      final response = await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: {
          'version': 1,
          'tables': {
            'items': [
              {'this': 'is not an item'},
            ],
          },
        },
      );
      expect(
        response.statusCode,
        400,
        reason: 'a bad file is the caller\'s problem, not a server error',
      );
      expect(response.json['error']['message'], contains('could not be read'));

      final items = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(
        items.json['total'],
        1,
        reason: 'the workspace it refused to replace is still here',
      );
    });

    test('an empty backup is refused rather than obeyed', () async {
      final session = await admin();
      await seed(session);

      final response = await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: {'version': 1, 'tables': <String, Object?>{}},
      );

      expect(response.statusCode, 400);
      final items = await server.get(
        '/inventory/items',
        accessToken: session.accessToken,
      );
      expect(items.json['total'], 1);
    });

    test('a backup from a newer format is refused', () async {
      final session = await admin();
      final response = await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: {
          'version': 99,
          'tables': {
            'items': [
              {'id': 'x'},
            ],
          },
        },
      );
      expect(response.statusCode, 400);
      expect(response.json['error']['message'], contains('newer version'));
    });

    test('a file that is not a backup is refused', () async {
      final session = await admin();
      final response = await server.post(
        '/inventory/restore',
        accessToken: session.accessToken,
        body: {'hello': 'world'},
      );
      expect(response.statusCode, 400);
    });

    test('a photo-sized body is accepted', () async {
      // The cap was 64 KiB, which is smaller than any photograph. An item
      // carries its photo inline as base64, so this was not a limit on abuse
      // — it was the photo feature not working.
      final session = await admin();

      final response = await server.post(
        '/inventory/items',
        accessToken: session.accessToken,
        body: {
          'name': 'Photographed',
          'quantity': 1,
          'photo': 'data:image/png;base64,${'A' * 200000}',
        },
      );

      expect(response.statusCode, 201);
    });

    test('a company logo is accepted', () async {
      final session = await admin();

      final response = await server.patch(
        '/inventory/preferences',
        accessToken: session.accessToken,
        body: {
          'preferences': {
            'companyLogo': 'data:image/png;base64,${'A' * 200000}',
          },
        },
      );

      expect(response.statusCode, 200);
    });

    test('staff can neither back up nor restore', () async {
      final staff = await server.signedInUser(email: 'hand2@example.com');

      final backup = await server.get(
        '/inventory/backup',
        accessToken: staff.accessToken,
      );
      expect(backup.statusCode, 403);

      final restore = await server.post(
        '/inventory/restore',
        accessToken: staff.accessToken,
        body: {'version': 1, 'tables': <String, Object?>{}},
      );
      expect(restore.statusCode, 403);
    });
  });
}
