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

  Future<String> createItemWithCost(
    TestSession s, {
    required int quantity,
    required double unitCost,
  }) async {
    final response = await server.post(
      '/inventory/items',
      accessToken: s.accessToken,
      body: {
        'name': 'Widget',
        'quantity': quantity,
        'unitCost': unitCost,
        'location': 'Main',
      },
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

  group('a blank document id means "mint one"', () {
    test('a second invoice can be raised', () async {
      // The client builds a draft with id: '' and toJson always sends the key,
      // so this is the shape the app actually posts — not the id-less body the
      // other tests here use.
      final s = await admin();
      final id = await item(s, quantity: 50);

      Future<String> raise(String customer) async {
        final response = await server.post(
          '/documents/invoices',
          accessToken: s.accessToken,
          body: {
            'id': '',
            'reference': '',
            'customerName': customer,
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
            ],
          },
        );
        expect(response.statusCode, 201);
        return response.json['invoice']['id'] as String;
      }

      final first = await raise('One');
      final second = await raise('Two');

      expect(second, isNot(first));
      final list = await server.get(
        '/documents/invoices',
        accessToken: s.accessToken,
      );
      expect((list.json['invoices'] as List).length, 2);
    });

    test('a second receipt can be issued', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);

      Future<String> issue() async {
        final response = await server.post(
          '/documents/receipts',
          accessToken: s.accessToken,
          body: {
            'id': '',
            'reference': '',
            'status': 'issued',
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
            ],
          },
        );
        expect(response.statusCode, 201);
        return response.json['receipt']['id'] as String;
      }

      expect(await issue(), isNot(await issue()));
    });

    test('a second order of each kind can be raised', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);

      for (final path in ['purchase-orders', 'sales-orders']) {
        final key = path == 'purchase-orders' ? 'purchaseOrder' : 'salesOrder';
        final quantityKey = 'quantityOrdered';
        final ids = <String>{};
        for (var i = 0; i < 2; i++) {
          final response = await server.post(
            '/documents/$path',
            accessToken: s.accessToken,
            body: {
              'id': '',
              'reference': '',
              'lines': [
                {'itemId': id, 'itemName': 'Widget', quantityKey: 1},
              ],
            },
          );
          expect(response.statusCode, 201, reason: path);
          ids.add(response.json[key]['id'] as String);
        }
        expect(ids.length, 2, reason: '$path reused an id');
      }
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
      expect(voided.json['receipt']['status'], 'voided');
      expect(await quantityOf(s, id), 10);
    });
  });

  group('refunds', () {
    Future<(String, String)> issuedReceipt(TestSession s, String itemId) async {
      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantity': 5,
              'unitPrice': 2.0,
            },
          ],
        },
      );
      return (
        created.json['receipt']['id'] as String,
        created.json['receipt']['lines'][0]['id'] as String,
      );
    }

    test('a partial return puts back only what came back', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (receiptId, lineId) = await issuedReceipt(s, id);
      expect(await quantityOf(s, id), 5);

      final refunded = await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 2},
        },
      );

      expect(refunded.json['receipt']['status'], 'partRefunded');
      expect(refunded.json['receipt']['lines'][0]['quantityRefunded'], 2);
      expect(await quantityOf(s, id), 7);
    });

    test('returning everything settles the receipt', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (receiptId, lineId) = await issuedReceipt(s, id);

      final refunded = await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 5},
        },
      );

      expect(refunded.json['receipt']['status'], 'refunded');
      expect(await quantityOf(s, id), 10);
    });

    test('broken goods are refunded but not restocked', () async {
      // Stock and money part company here, which is why restock is a flag
      // rather than something inferred from the return.
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (receiptId, lineId) = await issuedReceipt(s, id);
      expect(await quantityOf(s, id), 5);

      final refunded = await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 3},
          'restock': false,
        },
      );

      expect(refunded.json['receipt']['lines'][0]['quantityRefunded'], 3);
      expect(await quantityOf(s, id), 5, reason: 'nothing went back on');
    });

    test('a return is capped at what is still kept', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (receiptId, lineId) = await issuedReceipt(s, id);

      await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 4},
        },
      );
      final second = await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 9},
        },
      );

      expect(
        second.json['receipt']['lines'][0]['quantityRefunded'],
        5,
        reason: 'only the one still kept came back',
      );
      expect(await quantityOf(s, id), 10);
    });

    test('a voided receipt has nothing to refund', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (receiptId, lineId) = await issuedReceipt(s, id);

      await server.post(
        '/documents/receipts/$receiptId/void',
        accessToken: s.accessToken,
        body: {'reason': 'Wrong item'},
      );
      final response = await server.post(
        '/documents/receipts/$receiptId/refund',
        accessToken: s.accessToken,
        body: {
          'returned': {lineId: 1},
        },
      );

      expect(response.statusCode, 400);
    });
  });

  group('a counter sale meets the shelf', () {
    test('the ledger ties the movement to the receipt', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 2},
          ],
        },
      );
      final receiptId = created.json['receipt']['id'] as String;

      final history = await server.get(
        '/inventory/movements?item=$id',
        accessToken: s.accessToken,
      );
      final tagged = (history.json['movements'] as List).where(
        (m) => m['documentId'] == receiptId,
      );
      expect(
        tagged,
        isNotEmpty,
        reason: 'a sale has to be traceable back to the document',
      );
    });

    test('two lines for one item draw down the same stock', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 3},
            {'itemId': id, 'itemName': 'Widget', 'quantity': 4},
          ],
        },
      );

      expect(created.statusCode, 201);
      expect(
        await quantityOf(s, id),
        3,
        reason: 'seven left the shelf in total, not three or four',
      );
    });

    test('selling more than is there does not take the till with it', () async {
      // The on-device path trimmed the line to what was on the shelf and sold
      // that. Whatever the server does, it must not leave the stock half
      // moved: either the sale stands or nothing changed.
      final s = await admin();
      final id = await item(s, quantity: 2);

      final response = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 9},
          ],
        },
      );

      final after = await quantityOf(s, id);
      if (response.statusCode >= 400) {
        expect(after, 2, reason: 'refused, so nothing moved');
      } else {
        expect(after, greaterThanOrEqualTo(0));
      }
    });
  });

  group('void and refund together', () {
    test(
      'voiding after a partial refund returns only what is still out',
      () async {
        // The on-device path refused this outright: once goods have come back
        // the document has a history worth keeping. The server allows it, and
        // the arithmetic has to hold either way — the reversal is computed from
        // the movements the document actually wrote, so a refund already
        // returned is not returned twice.
        final s = await admin();
        final id = await item(s, quantity: 10);

        final created = await server.post(
          '/documents/receipts',
          accessToken: s.accessToken,
          body: {
            'status': 'issued',
            'movesStock': true,
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantity': 6},
            ],
          },
        );
        final receiptId = created.json['receipt']['id'] as String;
        final lineId = created.json['receipt']['lines'][0]['id'] as String;
        expect(await quantityOf(s, id), 4);

        await server.post(
          '/documents/receipts/$receiptId/refund',
          accessToken: s.accessToken,
          body: {
            'returned': {lineId: 2},
          },
        );
        expect(await quantityOf(s, id), 6);

        await server.post(
          '/documents/receipts/$receiptId/void',
          accessToken: s.accessToken,
          body: {'reason': 'Struck off'},
        );

        expect(
          await quantityOf(s, id),
          10,
          reason: 'the four still out came back, not six',
        );
      },
    );

    test('voiding twice does not return the stock twice', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 3},
          ],
        },
      );
      final receiptId = created.json['receipt']['id'] as String;

      await server.post(
        '/documents/receipts/$receiptId/void',
        accessToken: s.accessToken,
        body: {'reason': 'once'},
      );
      await server.post(
        '/documents/receipts/$receiptId/void',
        accessToken: s.accessToken,
        body: {'reason': 'twice'},
      );

      expect(await quantityOf(s, id), 10);
    });

    test('each kind of document counts in its own sequence', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);

      final invoice = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );
      final receipt = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 1},
          ],
        },
      );

      // Both are the first of their kind, so both end 0001 — a shared counter
      // would have made the second 0002.
      expect(invoice.json['invoice']['reference'], 'INV-0001');
      expect(receipt.json['receipt']['reference'], 'RCP-0001');
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

  group('what a delivery does to cost', () {
    Future<double> costOf(TestSession s, String id) async {
      final response = await server.get(
        '/inventory/items/$id',
        accessToken: s.accessToken,
      );
      return (response.json['item']['unitCost'] as num).toDouble();
    }

    Future<(String, String)> order(
      TestSession s,
      String itemId, {
      required int quantity,
      required double unitCost,
    }) async {
      final created = await server.post(
        '/documents/purchase-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'ordered',
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantityOrdered': quantity,
              'unitCost': unitCost,
            },
          ],
        },
      );
      return (
        created.json['purchaseOrder']['id'] as String,
        created.json['purchaseOrder']['lines'][0]['id'] as String,
      );
    }

    test('cost is rolled forward as a weighted average', () async {
      // Ten on hand at 1.00, ten more arriving at 2.00, so the shelf is now
      // worth 30 across twenty units. Leaving the cost at 1.00 would overstate
      // every margin reported from then on.
      final s = await admin();
      final id = await createItemWithCost(s, quantity: 10, unitCost: 1.0);

      final (orderId, lineId) = await order(s, id, quantity: 10, unitCost: 2.0);
      await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 10},
        },
      );

      expect(await quantityOf(s, id), 20);
      expect(await costOf(s, id), closeTo(1.5, 0.0001));
    });

    test('cost is taken as-is when there was nothing to average', () async {
      final s = await admin();
      final id = await createItemWithCost(s, quantity: 0, unitCost: 0);

      final (orderId, lineId) = await order(s, id, quantity: 4, unitCost: 3.25);
      await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 4},
        },
      );

      expect(await costOf(s, id), closeTo(3.25, 0.0001));
    });

    test('a zero-cost line leaves the existing cost alone', () async {
      // A line with no price on it is missing information, not a statement
      // that the goods were free.
      final s = await admin();
      final id = await createItemWithCost(s, quantity: 5, unitCost: 4.0);

      final (orderId, lineId) = await order(s, id, quantity: 5, unitCost: 0);
      await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {lineId: 5},
        },
      );

      expect(await costOf(s, id), closeTo(4.0, 0.0001));
      expect(await quantityOf(s, id), 10);
    });

    test('a cancelled order takes no delivery', () async {
      final s = await admin();
      final id = await createItemWithCost(s, quantity: 0, unitCost: 1);
      final (orderId, lineId) = await order(s, id, quantity: 5, unitCost: 1);

      await server.patch(
        '/documents/purchase-orders/$orderId',
        accessToken: s.accessToken,
        body: {
          'status': 'cancelled',
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantityOrdered': 5,
              'unitCost': 1.0,
            },
          ],
        },
      );

      // Re-read the line id: saving replaces the lines wholesale, so the one
      // from before the edit no longer exists — and a 400 for *that* reason
      // would pass this test without proving anything about cancellation.
      final reread = await server.get(
        '/documents/purchase-orders/$orderId',
        accessToken: s.accessToken,
      );
      final currentLineId =
          reread.json['purchaseOrder']['lines'][0]['id'] as String;
      expect(currentLineId, isNot(lineId));

      final response = await server.post(
        '/documents/purchase-orders/$orderId/receive',
        accessToken: s.accessToken,
        body: {
          'received': {currentLineId: 5},
        },
      );

      expect(response.statusCode, 400);
      expect(await quantityOf(s, id), 0);
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

  group('despatch', () {
    test('despatching moves stock and fulfils the line', () async {
      final s = await admin();
      final id = await item(s, quantity: 12);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
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
      final orderId = created.json['salesOrder']['id'] as String;
      final lineId = created.json['salesOrder']['lines'][0]['id'] as String;
      expect(await quantityOf(s, id), 12, reason: 'confirming moves nothing');

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 3},
        },
      );

      expect(sent.json['salesOrder']['status'], 'partial');
      expect(sent.json['salesOrder']['lines'][0]['quantityFulfilled'], 3);
      expect(await quantityOf(s, id), 9);
    });

    test('a despatch is limited by the shelf, not just the order', () async {
      // The constraint a delivery does not have: another device may have sold
      // the last of it since this order was opened.
      final s = await admin();
      final id = await item(s, quantity: 2);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 10},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;
      final lineId = created.json['salesOrder']['lines'][0]['id'] as String;

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 10},
        },
      );

      expect(
        sent.json['salesOrder']['lines'][0]['quantityFulfilled'],
        2,
        reason: 'only what was on the shelf',
      );
      expect(await quantityOf(s, id), 0);
      expect(sent.json['salesOrder']['status'], 'partial');
    });

    test('an order is fulfilled once every line has gone', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 4},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;
      final lineId = created.json['salesOrder']['lines'][0]['id'] as String;

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 4},
        },
      );

      expect(sent.json['salesOrder']['status'], 'fulfilled');
      expect(await quantityOf(s, id), 6);
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
