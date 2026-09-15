import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

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

  Future<String> item(TestSession s, {int quantity = 20}) async {
    final response = await server.post(
      '/inventory/items',
      accessToken: s.accessToken,
      body: {'name': 'Widget', 'quantity': quantity, 'location': 'Main'},
    );
    return response.json['item']['id'] as String;
  }

  Future<int> quantityOf(TestSession s, String id) async {
    final response = await server.get(
      '/inventory/items/$id',
      accessToken: s.accessToken,
    );
    return response.json['item']['quantity'] as int;
  }

  group('invoices', () {
    test('issuing one takes the stock it sells', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);

      final response = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 3,
              'unitPrice': 5.0,
            },
          ],
        },
      );

      expect(response.statusCode, 201);
      expect(response.json['invoice']['lines'].length, 1);
      expect(await quantityOf(s, id), 17);
    });

    test('a proforma prints but does not move stock', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);

      await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': false,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 8,
              'unitPrice': 5.0,
            },
          ],
        },
      );

      expect(await quantityOf(s, id), 20);
    });

    test('re-saving does not take the stock twice', () async {
      // Whether the effect has been applied is answered by asking for the
      // document's movements, so a retried save is a no-op rather than a
      // second deduction nobody notices until the shelf disagrees.
      final s = await admin();
      final id = await item(s, quantity: 20);

      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 5.0,
            },
          ],
        },
      );
      expect(await quantityOf(s, id), 16);

      final invoiceId = created.json['invoice']['id'] as String;
      await server.patch(
        '/documents/invoices/$invoiceId',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer renamed',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 5.0,
            },
          ],
        },
      );

      expect(await quantityOf(s, id), 16, reason: 'still once, not twice');
    });

    test('cancelling puts the stock back', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);

      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 6,
              'unitPrice': 5.0,
            },
          ],
        },
      );
      expect(await quantityOf(s, id), 14);

      final invoiceId = created.json['invoice']['id'] as String;
      final cancelled = await server.post(
        '/documents/invoices/$invoiceId/cancel',
        accessToken: s.accessToken,
        body: {'reason': 'Ordered in error'},
      );

      expect(cancelled.json['invoice']['status'], 'cancelled');
      expect(await quantityOf(s, id), 20);
    });

    test('the reversal is recorded, not silent', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);

      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 2,
              'unitPrice': 5.0,
            },
          ],
        },
      );
      await server.post(
        '/documents/invoices/${created.json['invoice']['id']}/cancel',
        accessToken: s.accessToken,
        body: {'reason': 'Changed their mind'},
      );

      final history = await server.get(
        '/inventory/movements?item=$id',
        accessToken: s.accessToken,
      );
      final kinds = [
        for (final m in history.json['movements'] as List) m['kind'] as String,
      ];
      expect(kinds, contains('sale'));
      expect(kinds, contains('cancellation'));
    });

    test('references are allocated, not left blank', () async {
      final s = await admin();
      final id = await item(s);

      final first = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );
      final second = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );

      final a = first.json['invoice']['reference'] as String;
      final b = second.json['invoice']['reference'] as String;
      expect(a, startsWith('INV-'));
      expect(b, isNot(a), reason: 'two invoices cannot share a number');
    });
  });

  group('receipts', () {
    test('issuing takes stock and voiding returns it', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 2.0,
            },
          ],
        },
      );
      expect(created.statusCode, 201);
      expect(await quantityOf(s, id), 6);

      final voided = await server.post(
        '/documents/receipts/${created.json['receipt']['id']}/void',
        accessToken: s.accessToken,
        body: {'reason': 'Wrong item'},
      );
      expect(voided.json['receipt']['status'], 'void');
      expect(await quantityOf(s, id), 10);
    });
  });

  group('purchase orders', () {
    test('ordering does not move stock; receiving does', () async {
      final s = await admin();
      final id = await item(s, quantity: 5);

      final created = await server.post(
        '/documents/purchase-orders',
        accessToken: s.accessToken,
        body: {
          'supplierName': 'A supplier',
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantityOrdered': 10,
              'unitCost': 1.0,
            },
          ],
        },
      );
      expect(created.statusCode, 201);
      expect(await quantityOf(s, id), 5, reason: 'ordering is not receiving');

      final orderId = created.json['purchaseOrder']['id'] as String;
      final lineId = created.json['purchaseOrder']['lines'][0]['id'] as String;

      final received = await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 4},
          'location': 'Main',
        },
      );

      expect(received.json['purchaseOrder']['status'], 'partial');
      expect(received.json['purchaseOrder']['lines'][0]['quantityReceived'], 4);
      expect(await quantityOf(s, id), 9);
    });

    test('an order is complete once every line has arrived', () async {
      final s = await admin();
      final id = await item(s, quantity: 0);

      final created = await server.post(
        '/documents/purchase-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 3},
          ],
        },
      );
      final orderId = created.json['purchaseOrder']['id'] as String;
      final lineId = created.json['purchaseOrder']['lines'][0]['id'] as String;

      final received = await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 3},
        },
      );

      expect(received.json['purchaseOrder']['status'], 'received');
      expect(await quantityOf(s, id), 3);
    });

    test('receiving more than was ordered is refused', () async {
      final s = await admin();
      final id = await item(s, quantity: 0);

      final created = await server.post(
        '/documents/purchase-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 2},
          ],
        },
      );
      final orderId = created.json['purchaseOrder']['id'] as String;
      final lineId = created.json['purchaseOrder']['lines'][0]['id'] as String;

      final response = await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 9},
        },
      );

      expect(response.statusCode, 400);
      expect(await quantityOf(s, id), 0, reason: 'nothing applied');
    });
  });

  group('sales orders', () {
    test('committing to sell does not move stock', () async {
      // The invoice or receipt raised against it does that. An order that
      // deducted on confirmation would double-count the moment one is raised.
      final s = await admin();
      final id = await item(s, quantity: 12);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'status': 'confirmed',
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantityOrdered': 5,
              'unitPrice': 4.0,
            },
          ],
        },
      );

      expect(created.statusCode, 201);
      expect(created.json['salesOrder']['reference'], startsWith('SO-'));
      expect(await quantityOf(s, id), 12);
    });
  });

  group('shared and guarded', () {
    test('a document raised by one user is visible to another', () async {
      final owner = await admin();
      final id = await item(owner);
      await server.post(
        '/documents/invoices',
        accessToken: owner.accessToken,
        body: {
          'customerName': 'Shared',
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );

      final other = await server.signedInUser(email: 'other@example.com');
      final list = await server.get(
        '/documents/invoices',
        accessToken: other.accessToken,
      );
      expect(list.statusCode, 200);
      expect((list.json['invoices'] as List).length, 1);
    });

    test('staff cannot raise an invoice', () async {
      final owner = await admin();
      final id = await item(owner);
      final staff = await server.signedInUser(email: 'staff@example.com');

      final response = await server.post(
        '/documents/invoices',
        accessToken: staff.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );
      expect(response.statusCode, 403);
    });
  });
}
