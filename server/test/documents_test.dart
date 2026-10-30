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

  group('payments', () {
    Future<(String, double)> invoiceFor(
      TestSession s,
      String itemId, {
      int quantity = 4,
      double unitPrice = 25.0,
      double taxRate = 0,
      double discount = 0,
    }) async {
      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'taxRate': taxRate,
          'discount': discount,
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantity': quantity,
              'unitPrice': unitPrice,
            },
          ],
        },
      );
      return (created.json['invoice']['id'] as String, quantity * unitPrice);
    }

    Future<double> paidOn(TestSession s, String id) async {
      final read = await server.get(
        '/documents/invoices/$id',
        accessToken: s.accessToken,
      );
      return (read.json['invoice']['amountPaid'] as num).toDouble();
    }

    test('two payments accumulate rather than overwrite', () async {
      // The reason this is an endpoint at all. While amountPaid was a field
      // each client wrote, two tills settling the same invoice each sent their
      // own total and the second silently replaced the first.
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, _) = await invoiceFor(s, id);

      await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 30.0},
      );
      await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 20.0},
      );

      expect(await paidOn(s, invoiceId), closeTo(50.0, 0.0001));
    });

    test('paying it off in full settles the invoice', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, total) = await invoiceFor(s, id);

      final response = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': total},
      );

      expect(response.json['invoice']['status'], 'paid');
      expect(response.json['invoice']['closedAt'], isNotNull);
    });

    test('a part payment leaves it part paid', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, total) = await invoiceFor(s, id);

      final response = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': total / 2},
      );

      expect(response.json['invoice']['status'], 'partPaid');
    });

    test('a payment never exceeds the balance', () async {
      // Anything beyond the balance is change, not revenue. An invoice that
      // reads as more than paid is a figure nobody can reconcile.
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, total) = await invoiceFor(s, id);

      final response = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': total + 500},
      );

      expect(
        (response.json['applied'] as num).toDouble(),
        closeTo(total, 0.0001),
      );
      expect(await paidOn(s, invoiceId), closeTo(total, 0.0001));
      expect(response.json['invoice']['status'], 'paid');
    });

    test('a settled invoice takes no further payment', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, total) = await invoiceFor(s, id);

      await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': total},
      );
      final again = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 10.0},
      );

      expect(again.statusCode, 400);
      expect(await paidOn(s, invoiceId), closeTo(total, 0.0001));
    });

    test('the balance is computed from tax and discount too', () async {
      // Duplicated from the client rather than trusted from the request: a
      // balance the payer supplies is one the payer can be wrong about.
      final s = await admin();
      final id = await item(s, quantity: 50);
      // 4 x 25 = 100, less 20 discount = 80, plus 10% tax = 88.
      final (invoiceId, _) = await invoiceFor(
        s,
        id,
        taxRate: 0.1,
        discount: 20.0,
      );

      final response = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 1000.0},
      );

      expect((response.json['applied'] as num).toDouble(), closeTo(88.0, 0.01));
      expect(response.json['invoice']['status'], 'paid');
    });

    test('a cancelled invoice takes no payment', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, _) = await invoiceFor(s, id);

      await server.post(
        '/documents/invoices/$invoiceId/cancel',
        accessToken: s.accessToken,
        body: {'reason': 'Ordered in error'},
      );
      final response = await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 10.0},
      );

      expect(response.statusCode, 400);
    });

    test('nothing, or less than nothing, is not a payment', () async {
      final s = await admin();
      final id = await item(s, quantity: 50);
      final (invoiceId, _) = await invoiceFor(s, id);

      for (final amount in [0.0, -25.0]) {
        final response = await server.post(
          '/documents/invoices/$invoiceId/payments',
          accessToken: s.accessToken,
          body: {'amount': amount},
        );
        expect(response.statusCode, 400, reason: 'amount $amount');
      }
      expect(await paidOn(s, invoiceId), 0);
    });
  });

  group('money already taken', () {
    test('an invoice with a payment against it cannot be cancelled', () async {
      // Cancelling returns the stock. If money has been taken against the
      // invoice, that leaves the goods back on the shelf and the payment still
      // banked — the books and the shelf disagree, and nothing on either side
      // records why.
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'customerName': 'A customer',
          'movesStock': true,
          'amountPaid': 25.0,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 10.0,
            },
          ],
        },
      );
      final invoiceId = created.json['invoice']['id'] as String;
      expect(await quantityOf(s, id), 6);

      final response = await server.post(
        '/documents/invoices/$invoiceId/cancel',
        accessToken: s.accessToken,
        body: {'reason': 'Ordered in error'},
      );

      expect(response.statusCode, 400);
      expect(
        await quantityOf(s, id),
        6,
        reason: 'the stock stayed out, because the money stayed in',
      );

      final read = await server.get(
        '/documents/invoices/$invoiceId',
        accessToken: s.accessToken,
      );
      expect(read.json['invoice']['status'], isNot('cancelled'));
    });

    test('an unpaid invoice still cancels', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'movesStock': true,
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantity': 4},
          ],
        },
      );

      final response = await server.post(
        '/documents/invoices/${created.json['invoice']['id']}/cancel',
        accessToken: s.accessToken,
        body: {'reason': 'Ordered in error'},
      );

      expect(response.statusCode, 200);
      expect(response.json['invoice']['status'], 'cancelled');
      expect(await quantityOf(s, id), 10);
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

    // SETTLING HAD NOWHERE TO GO. A receipt left owing was marked paid on the
    // till's own screen and the server never heard, so the next load showed it
    // outstanding again.
    Future<String> owing(TestSession s, String itemId) async {
      final created = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'status': 'issued',
          'movesStock': true,
          'amountPaid': 0,
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 25.0,
            },
          ],
        },
      );
      return created.json['receipt']['id'] as String;
    }

    test('a payment against a receipt sticks', () async {
      final s = await admin();
      final id = await owing(s, await item(s));

      final paid = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 40.0},
      );

      expect(paid.statusCode, 200);
      expect(paid.json['applied'], 40.0);
      expect(paid.json['receipt']['amountPaid'], 40.0);
    });

    test('payments add rather than overwrite', () async {
      // Two tills taking money against the same receipt must accumulate.
      final s = await admin();
      final id = await owing(s, await item(s));

      await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 30.0},
      );
      final second = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 20.0},
      );

      expect(second.json['receipt']['amountPaid'], 50.0);
    });

    test('paying more than is owed takes only the balance', () async {
      final s = await admin();
      final id = await owing(s, await item(s));

      final paid = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 500.0},
      );

      expect(
        paid.json['applied'],
        100.0,
        reason: 'the rest is the customer\'s change, not the shop\'s money',
      );
      expect(paid.json['receipt']['amountPaid'], 100.0);
    });

    test('a settled receipt refuses another payment', () async {
      final s = await admin();
      final id = await owing(s, await item(s));
      await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 100.0},
      );

      final again = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 10.0},
      );

      expect(again.statusCode, 400);
      expect(again.json['error']['message'], contains('already settled'));
    });

    test('a voided receipt takes no payment', () async {
      final s = await admin();
      final id = await owing(s, await item(s));
      await server.post(
        '/documents/receipts/$id/void',
        accessToken: s.accessToken,
        body: {'reason': 'Wrong item'},
      );

      final paid = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 10.0},
      );

      expect(paid.statusCode, 400);
    });

    test('nothing is not a payment', () async {
      final s = await admin();
      final id = await owing(s, await item(s));

      final paid = await server.post(
        '/documents/receipts/$id/payments',
        accessToken: s.accessToken,
        body: {'amount': 0},
      );

      expect(paid.statusCode, 400);
    });
  });

  // THE LIST ENDPOINTS WERE N+1: each fetched its rows and then, per row,
  // called the single-document reader — which re-selects the row and queries
  // its lines, awaited in turn. 1 + 200 x 2 round trips to answer one request,
  // five such lists fetched in parallel at startup. They batch now, and the
  // risk a batch carries is grouping: lines landing on the wrong document.
  group('a list and its lines', () {
    test('every receipt keeps its own lines, in order', () async {
      final s = await admin();
      final id = await item(s, quantity: 500);

      for (var r = 0; r < 3; r++) {
        await server.post(
          '/documents/receipts',
          accessToken: s.accessToken,
          body: {
            'status': 'issued',
            'movesStock': true,
            'lines': [
              // A different count per receipt, and a name that says which
              // receipt and which line it belongs to.
              for (var l = 0; l <= r; l++)
                {
                  'itemId': id,
                  'itemName': 'R$r-L$l',
                  'quantity': 1,
                  'unitPrice': 2.0,
                },
            ],
          },
        );
      }

      final listed = await server.get(
        '/documents/receipts',
        accessToken: s.accessToken,
      );
      final rows = listed.json['receipts'] as List;
      expect(rows, hasLength(3));

      // Newest first, so receipt 2 (three lines) leads.
      for (final row in rows) {
        final lines = (row as Map)['lines'] as List;
        final names = [for (final l in lines) (l as Map)['itemName'] as String];
        final receipt = names.first.split('-').first;
        expect(names, [
          for (var l = 0; l < names.length; l++) '$receipt-L$l',
        ], reason: 'lines belong to one receipt and keep their order');
      }

      expect(
        [for (final r in rows) ((r as Map)['lines'] as List).length]..sort(),
        [1, 2, 3],
      );
    });

    test(
      'a document with no lines comes back with none, not somebody else\'s',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 50);

        await server.post(
          '/documents/receipts',
          accessToken: s.accessToken,
          body: {
            'status': 'issued',
            'movesStock': true,
            'lines': [
              {
                'itemId': id,
                'itemName': 'Only one',
                'quantity': 1,
                'unitPrice': 2.0,
              },
            ],
          },
        );
        await server.post(
          '/documents/receipts',
          accessToken: s.accessToken,
          body: {'status': 'issued', 'movesStock': false, 'lines': <Object?>[]},
        );

        final listed = await server.get(
          '/documents/receipts',
          accessToken: s.accessToken,
        );
        final counts = [
          for (final r in listed.json['receipts'] as List)
            ((r as Map)['lines'] as List).length,
        ]..sort();

        expect(counts, [0, 1]);
      },
    );

    test('an empty list asks for no lines at all', () async {
      final s = await admin();

      final listed = await server.get(
        '/documents/receipts',
        accessToken: s.accessToken,
      );

      expect(listed.statusCode, 200);
      expect(listed.json['receipts'], isEmpty);
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
      expect(receipt.json['receipt']['reference'], 'RC-0001');
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
      final id = await item(s, quantity: 10);

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
      // Ordered while there were ten; someone else sells eight meanwhile.
      await server.post(
        '/inventory/stock/adjust',
        accessToken: s.accessToken,
        body: {'itemId': id, 'delta': -8, 'kind': 'sale'},
      );

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

  group('what a sale can still be sent', () {
    Future<(String, String)> confirmed(
      TestSession s,
      String itemId, {
      int ordered = 5,
    }) async {
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantityOrdered': ordered,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      return (
        created.json['salesOrder']['id'] as String,
        created.json['salesOrder']['lines'][0]['id'] as String,
      );
    }

    test('sending more than ordered is clamped to the balance', () async {
      // Two separate ceilings: the order and the shelf. This one has plenty on
      // the shelf, so the order is what binds.
      final s = await admin();
      final id = await item(s, quantity: 100);
      final (orderId, lineId) = await confirmed(s, id, ordered: 5);

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 40},
        },
      );

      expect(sent.json['salesOrder']['lines'][0]['quantityFulfilled'], 5);
      expect(sent.json['salesOrder']['status'], 'fulfilled');
      expect(await quantityOf(s, id), 95);
    });

    test('a second send tops up rather than starting again', () async {
      final s = await admin();
      final id = await item(s, quantity: 100);
      final (orderId, lineId) = await confirmed(s, id, ordered: 10);

      await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 4},
        },
      );
      final second = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 4},
        },
      );

      expect(second.json['salesOrder']['lines'][0]['quantityFulfilled'], 8);
      expect(second.json['salesOrder']['status'], 'partial');
      expect(await quantityOf(s, id), 92);
    });

    test('a send with nothing on the shelf moves nothing', () async {
      final s = await admin();
      final id = await item(s, quantity: 5);
      final (orderId, lineId) = await confirmed(s, id, ordered: 5);
      // The shelf empties after the order was taken.
      await server.post(
        '/inventory/stock/adjust',
        accessToken: s.accessToken,
        body: {'itemId': id, 'delta': -5, 'kind': 'sale'},
      );

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 5},
        },
      );

      expect(sent.statusCode, 200);
      expect(sent.json['salesOrder']['lines'][0]['quantityFulfilled'], 0);
      expect(await quantityOf(s, id), 0);
      expect(
        sent.json['salesOrder']['status'],
        'partial',
        reason: 'nothing went, so nothing is fulfilled',
      );
    });

    test('cost of goods is banked at the cost on the day it shipped', () async {
      // Read from the item at despatch, not from the order. A price agreed
      // weeks ago says nothing about what the stock cost when it left.
      final s = await admin();
      final response = await server.post(
        '/inventory/items',
        accessToken: s.accessToken,
        body: {
          'name': 'Widget',
          'quantity': 10,
          'unitCost': 2.5,
          'location': 'Main',
        },
      );
      final id = response.json['item']['id'] as String;
      final (orderId, lineId) = await confirmed(s, id, ordered: 4);

      final sent = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 4},
        },
      );

      expect(
        (sent.json['salesOrder']['lines'][0]['costOfGoods'] as num).toDouble(),
        closeTo(10.0, 0.0001),
        reason: 'four units at 2.50',
      );
    });

    test('each send raises a movement tagged with the sale', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final (orderId, lineId) = await confirmed(s, id, ordered: 3);

      await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 3},
        },
      );

      final history = await server.get(
        '/inventory/movements?item=$id',
        accessToken: s.accessToken,
      );
      final tagged = (history.json['movements'] as List).where(
        (m) => m['documentId'] == orderId,
      );
      expect(tagged, isNotEmpty);
    });
  });

  group('a cancelled sale sends nothing', () {
    test('despatch is refused once the order is cancelled', () async {
      // The mirror of the cancelled purchase order. Both were unguarded; the
      // delivery side was found first only because its test was ported first.
      final s = await admin();
      final id = await item(s, quantity: 10);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 4},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;

      final cancelled = await server.post(
        '/documents/sales-orders/$orderId/cancel',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );
      expect(cancelled.statusCode, 200);
      final lineId = cancelled.json['salesOrder']['lines'][0]['id'] as String;

      final response = await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 4},
        },
      );

      expect(response.statusCode, 400);
      expect(await quantityOf(s, id), 10, reason: 'nothing left the shelf');
    });
  });

  group('cancelling a sale returns what it sent', () {
    Future<(String, String)> sale(
      TestSession s,
      String itemId, {
      int ordered = 5,
    }) async {
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantityOrdered': ordered,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      return (
        created.json['salesOrder']['id'] as String,
        created.json['salesOrder']['lines'][0]['id'] as String,
      );
    }

    Future<void> send(TestSession s, String orderId, String lineId, int n) =>
        server.post(
          '/documents/sales-orders/$orderId/despatch',
          accessToken: s.accessToken,
          body: {
            'sent': {lineId: n},
          },
        );

    Future<ApiResponse> cancel(TestSession s, String orderId) => server.post(
      '/documents/sales-orders/$orderId/cancel',
      accessToken: s.accessToken,
      body: <String, Object?>{},
    );

    Future<String> invoiceFor(
      TestSession s,
      String orderId,
      String itemId,
    ) async {
      final response = await server.post(
        '/documents/invoices',
        accessToken: s.accessToken,
        body: {
          'salesOrderId': orderId,
          // Billing goods the order already sent: the invoice moves nothing.
          'movesStock': false,
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantity': 5,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      return response.json['invoice']['id'] as String;
    }

    test('a partly sent order puts back what went', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final (orderId, lineId) = await sale(s, id);
      await send(s, orderId, lineId, 3);
      expect(await quantityOf(s, id), 17);

      final response = await cancel(s, orderId);

      expect(response.statusCode, 200);
      expect(response.json['salesOrder']['status'], 'cancelled');
      expect(await quantityOf(s, id), 20);
    });

    test('a fully sent order can be cancelled and puts it all back', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id, ordered: 4);
      await send(s, orderId, lineId, 4);
      expect(await quantityOf(s, id), 6);

      final response = await cancel(s, orderId);

      expect(response.statusCode, 200);
      expect(response.json['salesOrder']['status'], 'cancelled');
      expect(await quantityOf(s, id), 10);
    });

    test('the return is recorded as a movement on the order', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id, ordered: 4);
      await send(s, orderId, lineId, 4);

      await cancel(s, orderId);

      final movements = await server.get(
        '/inventory/movements',
        accessToken: s.accessToken,
      );
      final onOrder = [
        for (final m in movements.json['movements'] as List)
          if (m['documentId'] == orderId) m,
      ];
      expect(
        onOrder.map((m) => m['kind']),
        containsAll(['sale', 'cancellation']),
      );
    });

    test('cancelling twice does not return the stock twice', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id, ordered: 4);
      await send(s, orderId, lineId, 4);

      await cancel(s, orderId);
      final again = await cancel(s, orderId);

      expect(again.statusCode, 200);
      expect(await quantityOf(s, id), 10);
    });

    test('an unsent order cancels and moves nothing', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, _) = await sale(s, id);

      final response = await cancel(s, orderId);

      expect(response.json['salesOrder']['status'], 'cancelled');
      expect(await quantityOf(s, id), 10);
    });

    test('an unpaid invoice billing the order is cancelled with it', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id);
      await send(s, orderId, lineId, 5);
      final invoiceId = await invoiceFor(s, orderId, id);

      final response = await cancel(s, orderId);

      expect(response.statusCode, 200);
      expect(response.json['invoices'].length, 1);
      expect(response.json['invoices'][0]['id'], invoiceId);
      expect(response.json['invoices'][0]['status'], 'cancelled');
      expect(await quantityOf(s, id), 10, reason: 'back once, not twice');
    });

    test('money taken against the sale blocks the cancel', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id);
      await send(s, orderId, lineId, 5);
      final invoiceId = await invoiceFor(s, orderId, id);
      await server.post(
        '/documents/invoices/$invoiceId/payments',
        accessToken: s.accessToken,
        body: {'amount': 5.0},
      );

      final response = await cancel(s, orderId);

      expect(response.statusCode, 400);
      expect(await quantityOf(s, id), 5, reason: 'nothing came back');
      final reread = await server.get(
        '/documents/sales-orders/$orderId',
        accessToken: s.accessToken,
      );
      expect(reread.json['salesOrder']['status'], isNot('cancelled'));
    });

    test('a plain save cannot cancel, or reopen, an order', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, lineId) = await sale(s, id);
      await send(s, orderId, lineId, 2);
      final lines = [
        {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 5},
      ];

      final sneaky = await server.patch(
        '/documents/sales-orders/$orderId',
        accessToken: s.accessToken,
        body: {'status': 'cancelled', 'lines': lines},
      );
      expect(sneaky.statusCode, 400);
      expect(await quantityOf(s, id), 8);

      await cancel(s, orderId);
      final reopen = await server.patch(
        '/documents/sales-orders/$orderId',
        accessToken: s.accessToken,
        body: {'status': 'confirmed', 'lines': lines},
      );
      expect(reopen.statusCode, 400);
    });
  });

  group('repairing sales cancelled the old way', () {
    // Before cancelling returned stock, an order was cancelled by flipping its
    // status. That is staged here directly in the database, because the API
    // no longer allows it.
    Future<({String orderId, String itemId})> legacyCancelled(
      TestSession s, {
      int onHand = 10,
      int sent = 4,
      bool invoice = false,
      double paid = 0,
    }) async {
      final itemId = await item(s, quantity: onHand);
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {'itemId': itemId, 'itemName': 'Widget', 'quantityOrdered': sent},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;
      final lineId = created.json['salesOrder']['lines'][0]['id'] as String;
      await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: sent},
        },
      );
      if (invoice) {
        final raised = await server.post(
          '/documents/invoices',
          accessToken: s.accessToken,
          body: {
            'salesOrderId': orderId,
            'movesStock': false,
            'lines': [
              {
                'itemId': itemId,
                'itemName': 'Widget',
                'quantity': sent,
                'unitPrice': 4.0,
              },
            ],
          },
        );
        final invoiceId = raised.json['invoice']['id'] as String;
        if (paid > 0) {
          await server.post(
            '/documents/invoices/$invoiceId/payments',
            accessToken: s.accessToken,
            body: {'amount': paid},
          );
        }
      }
      await server.customStatement(
        "UPDATE sales_orders SET status = 'cancelled' WHERE id = '$orderId'",
      );
      return (orderId: orderId, itemId: itemId);
    }

    Future<List<dynamic>> scan(TestSession s) async {
      final response = await server.get(
        '/documents/repairs/cancelled-sales',
        accessToken: s.accessToken,
      );
      expect(response.statusCode, 200);
      return response.json['issues'] as List;
    }

    Future<List<dynamic>> invoicesOf(TestSession s, String orderId) async {
      final response = await server.get(
        '/documents/invoices',
        accessToken: s.accessToken,
      );
      return [
        for (final i in response.json['invoices'] as List)
          if (i['salesOrderId'] == orderId) i,
      ];
    }

    test('the scan finds stock still out and live invoices', () async {
      final s = await admin();
      final legacy = await legacyCancelled(s, invoice: true);

      final issues = await scan(s);

      expect(issues.length, 1);
      expect(issues[0]['salesOrderId'], legacy.orderId);
      expect(issues[0]['stockOut'][0]['quantity'], 4);
      expect(issues[0]['liveInvoices'].length, 1);
      expect(issues[0]['fixable'], isTrue);
      expect(
        await quantityOf(s, legacy.itemId),
        6,
        reason: 'scan is read-only',
      );
    });

    test('a cancel done the new way leaves nothing to find', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 2},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;
      await server.post(
        '/documents/sales-orders/$orderId/cancel',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );

      expect(await scan(s), isEmpty);
    });

    test('repairing one returns the stock and cancels the invoice', () async {
      final s = await admin();
      final legacy = await legacyCancelled(s, invoice: true);

      final response = await server.post(
        '/documents/repairs/cancelled-sales/${legacy.orderId}',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );

      expect(response.statusCode, 200);
      expect(response.json['invoices'][0]['status'], 'cancelled');
      expect(await quantityOf(s, legacy.itemId), 10);
      expect(await scan(s), isEmpty);
    });

    test('repairing twice returns the stock once', () async {
      final s = await admin();
      final legacy = await legacyCancelled(s);
      for (var i = 0; i < 2; i++) {
        await server.post(
          '/documents/repairs/cancelled-sales/${legacy.orderId}',
          accessToken: s.accessToken,
          body: <String, Object?>{},
        );
      }
      expect(await quantityOf(s, legacy.itemId), 10);
    });

    test('a paid sale is reported but not repaired', () async {
      final s = await admin();
      final legacy = await legacyCancelled(s, invoice: true, paid: 5);

      final issues = await scan(s);
      expect(issues[0]['fixable'], isFalse);
      expect(issues[0]['paidBy'], isNotEmpty);

      final one = await server.post(
        '/documents/repairs/cancelled-sales/${legacy.orderId}',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );
      expect(one.statusCode, 400);

      final all = await server.post(
        '/documents/repairs/cancelled-sales',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );
      expect(all.json['repaired'], isEmpty);
      expect(all.json['skipped'].length, 1);
      expect(await quantityOf(s, legacy.itemId), 6);
    });

    test('repair all fixes every fixable sale and skips the paid', () async {
      final s = await admin();
      final a = await legacyCancelled(s);
      final b = await legacyCancelled(s, invoice: true);
      final paid = await legacyCancelled(s, invoice: true, paid: 5);

      final all = await server.post(
        '/documents/repairs/cancelled-sales',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );

      expect(all.json['repaired'].length, 2);
      expect(all.json['skipped'].length, 1);
      expect(await quantityOf(s, a.itemId), 10);
      expect(await quantityOf(s, b.itemId), 10);
      expect(await quantityOf(s, paid.itemId), 6);
    });

    test(
      'cancelling the live invoice by hand also returns the stock',
      () async {
        final s = await admin();
        final legacy = await legacyCancelled(s, invoice: true);
        final invoiceId = (await invoicesOf(s, legacy.orderId))[0]['id'];

        final response = await server.post(
          '/documents/invoices/$invoiceId/cancel',
          accessToken: s.accessToken,
          body: {'reason': 'Sale was cancelled'},
        );

        expect(response.statusCode, 200);
        expect(response.json['invoice']['status'], 'cancelled');
        expect(await quantityOf(s, legacy.itemId), 10);
        expect(await scan(s), isEmpty);
      },
    );

    test('only administrators can scan or repair', () async {
      final staff = await server.signedInUser(
        email: 'staff@example.com',
        role: staffRoleKey,
      );
      final response = await server.get(
        '/documents/repairs/cancelled-sales',
        accessToken: staff.accessToken,
      );
      expect(response.statusCode, 403);
    });
  });

  group('stock leaves when the sale is billed, not when it is ordered', () {
    Future<String> order(TestSession s, String itemId, {int qty = 10}) async {
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'customerName': 'Ada',
          'status': 'confirmed',
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantityOrdered': qty,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      return created.json['salesOrder']['id'] as String;
    }

    Future<ApiResponse> receipt(
      TestSession s,
      String orderId,
      String itemId,
      int qty, {
      double paid = 0,
    }) => server.post(
      '/documents/receipts',
      accessToken: s.accessToken,
      body: {
        'salesOrderId': orderId,
        'movesStock': true,
        'amountPaid': paid,
        'lines': [
          {
            'itemId': itemId,
            'itemName': 'Widget',
            'quantity': qty,
            'unitPrice': 4.0,
          },
        ],
      },
    );

    Future<ApiResponse> invoice(
      TestSession s,
      String orderId,
      String itemId,
      int qty,
    ) => server.post(
      '/documents/invoices',
      accessToken: s.accessToken,
      body: {
        'salesOrderId': orderId,
        'movesStock': true,
        'lines': [
          {
            'itemId': itemId,
            'itemName': 'Widget',
            'quantity': qty,
            'unitPrice': 4.0,
          },
        ],
      },
    );

    Future<Map<String, dynamic>> sale(TestSession s, String id) async =>
        (await server.get(
              '/documents/sales-orders/$id',
              accessToken: s.accessToken,
            )).json['salesOrder']
            as Map<String, dynamic>;

    test('a receipt for part of the order takes that part', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id);
      expect(await quantityOf(s, id), 20, reason: 'ordering moves nothing');

      final response = await receipt(s, orderId, id, 4, paid: 16);

      expect(response.statusCode, 201);
      expect(await quantityOf(s, id), 16);
      final now = await sale(s, orderId);
      expect(now['status'], 'partial');
      expect(now['lines'][0]['quantityFulfilled'], 4);
    });

    test('an invoice for the rest takes the rest and fulfils it', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id);
      await receipt(s, orderId, id, 4, paid: 16);

      final response = await invoice(s, orderId, id, 6);

      expect(response.statusCode, 201);
      expect(await quantityOf(s, id), 10);
      expect((await sale(s, orderId))['status'], 'fulfilled');
    });

    test('billing more than was ordered is refused', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id, qty: 5);
      await receipt(s, orderId, id, 3, paid: 12);

      final response = await invoice(s, orderId, id, 3);

      expect(response.statusCode, 400);
      expect(await quantityOf(s, id), 17);
    });

    test(
      'cancelling the invoice puts the stock back and reopens the line',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 20);
        final orderId = await order(s, id);
        final raised = await invoice(s, orderId, id, 10);
        final invoiceId = raised.json['invoice']['id'] as String;
        expect((await sale(s, orderId))['status'], 'fulfilled');

        await server.post(
          '/documents/invoices/$invoiceId/cancel',
          accessToken: s.accessToken,
          body: <String, Object?>{},
        );

        expect(await quantityOf(s, id), 20);
        final now = await sale(s, orderId);
        expect(now['status'], 'confirmed');
        expect(now['lines'][0]['quantityFulfilled'], 0);
        // And it can be billed again.
        expect((await invoice(s, orderId, id, 10)).statusCode, 201);
      },
    );

    test('voiding the receipt puts the stock back too', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id);
      final issued = await receipt(s, orderId, id, 4, paid: 16);
      final receiptId = issued.json['receipt']['id'] as String;

      await server.post(
        '/documents/receipts/$receiptId/void',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );

      expect(await quantityOf(s, id), 20);
      expect((await sale(s, orderId))['lines'][0]['quantityFulfilled'], 0);
    });

    test('goods sent the old way are billed without leaving twice', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id);
      final lineId = (await sale(s, orderId))['lines'][0]['id'] as String;
      await server.post(
        '/documents/sales-orders/$orderId/despatch',
        accessToken: s.accessToken,
        body: {
          'sent': {lineId: 6},
        },
      );
      expect(await quantityOf(s, id), 14);

      // Bills the six already sent, plus two more that leave now.
      await receipt(s, orderId, id, 8, paid: 32);

      expect(await quantityOf(s, id), 12);
      expect((await sale(s, orderId))['lines'][0]['quantityFulfilled'], 8);
    });

    test(
      'cancelling the sale voids an unpaid receipt and returns it',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 20);
        final orderId = await order(s, id);
        final issued = await receipt(s, orderId, id, 5);
        final receiptId = issued.json['receipt']['id'] as String;
        expect(await quantityOf(s, id), 15);

        final response = await server.post(
          '/documents/sales-orders/$orderId/cancel',
          accessToken: s.accessToken,
          body: <String, Object?>{},
        );

        expect(response.statusCode, 200);
        expect(await quantityOf(s, id), 20);
        final r = await server.get(
          '/documents/receipts/$receiptId',
          accessToken: s.accessToken,
        );
        expect(r.json['receipt']['status'], 'voided');
      },
    );

    test('a cancelled sale cannot be billed', () async {
      final s = await admin();
      final id = await item(s, quantity: 20);
      final orderId = await order(s, id);
      await server.post(
        '/documents/sales-orders/$orderId/cancel',
        accessToken: s.accessToken,
        body: <String, Object?>{},
      );

      expect((await invoice(s, orderId, id, 2)).statusCode, 400);
      expect(await quantityOf(s, id), 20);
    });
  });

  group('a new order cannot promise stock that is not there', () {
    test(
      'an order for more than is in stock is refused, and says why',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 5);

        final created = await server.post(
          '/documents/sales-orders',
          accessToken: s.accessToken,
          body: {
            'status': 'confirmed',
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 6},
            ],
          },
        );

        expect(created.statusCode, 400);
        expect(
          created.json['error']['message'],
          contains('Widget has only 5 in stock (6 ordered)'),
        );
        expect(await quantityOf(s, id), 5);
      },
    );

    test('an out-of-stock item is named as such', () async {
      final s = await admin();
      final id = await item(s, quantity: 0);

      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 1},
          ],
        },
      );

      expect(created.statusCode, 400);
      expect(created.json['error']['message'], contains('out of stock'));
    });

    test(
      'ordering exactly what is there is fine, and leaves it there',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 5);

        final created = await server.post(
          '/documents/sales-orders',
          accessToken: s.accessToken,
          body: {
            'status': 'confirmed',
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 5},
            ],
          },
        );

        expect(created.statusCode, 201);
        expect(await quantityOf(s, id), 5, reason: 'an order is not a sale');
      },
    );

    test('an order confirmed before the stock ran out can still be billed '
        'from what is left', () async {
      final s = await admin();
      final id = await item(s, quantity: 5);
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 5},
          ],
        },
      );
      final orderId = created.json['salesOrder']['id'] as String;

      final receipt = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'salesOrderId': orderId,
          'movesStock': true,
          'amountPaid': 20,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 5,
              'unitPrice': 4.0,
            },
          ],
        },
      );

      expect(receipt.statusCode, 201);
      expect(await quantityOf(s, id), 0, reason: '5 sold from 5 is 0');
    });

    test(
      'billing what is no longer on the shelf is refused, and says why',
      () async {
        final s = await admin();
        final id = await item(s, quantity: 5);
        final created = await server.post(
          '/documents/sales-orders',
          accessToken: s.accessToken,
          body: {
            'status': 'confirmed',
            'lines': [
              {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 5},
            ],
          },
        );
        final orderId = created.json['salesOrder']['id'] as String;
        await server.post(
          '/inventory/stock/adjust',
          accessToken: s.accessToken,
          body: {'itemId': id, 'delta': -3, 'kind': 'sale'},
        );

        final invoice = await server.post(
          '/documents/invoices',
          accessToken: s.accessToken,
          body: {
            'salesOrderId': orderId,
            'movesStock': true,
            'lines': [
              {
                'itemId': id,
                'itemName': 'Widget',
                'quantity': 5,
                'unitPrice': 4.0,
              },
            ],
          },
        );

        expect(invoice.statusCode, 400);
        expect(
          invoice.json['error']['message'],
          contains('Not enough Widget in stock: 2 on hand, 5 needed'),
        );
        expect(await quantityOf(s, id), 2);
      },
    );
  });

  group('reference numbers', () {
    test('a number already in use is skipped, not handed out again', () async {
      // Receipts imported with their own numbers never moved the counter, so
      // every new receipt was RC-0001 again and was refused: no receipt could
      // be issued and no invoice payment recorded.
      final s = await admin();
      final id = await item(s, quantity: 20);
      Future<ApiResponse> receipt({String reference = ''}) => server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          if (reference.isNotEmpty) 'reference': reference,
          'movesStock': false,
          'amountPaid': 4.0,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 1,
              'unitPrice': 4.0,
            },
          ],
        },
      );

      expect((await receipt(reference: 'RC-0001')).statusCode, 201);
      expect((await receipt(reference: 'RC-0002')).statusCode, 201);

      final issued = await receipt();

      expect(issued.statusCode, 201);
      expect(issued.json['receipt']['reference'], 'RC-0003');
      expect((await receipt()).json['receipt']['reference'], 'RC-0004');
    });
  });

  group('editing a sales order before it is billed', () {
    Future<(String, String)> confirmed(TestSession s, String itemId) async {
      final created = await server.post(
        '/documents/sales-orders',
        accessToken: s.accessToken,
        body: {
          'status': 'confirmed',
          'lines': [
            {
              'itemId': itemId,
              'itemName': 'Widget',
              'quantityOrdered': 3,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      return (
        created.json['salesOrder']['id'] as String,
        created.json['salesOrder']['reference'] as String,
      );
    }

    Future<ApiResponse> edit(
      TestSession s,
      String orderId,
      String itemId, {
      int qty = 5,
    }) => server.patch(
      '/documents/sales-orders/$orderId',
      accessToken: s.accessToken,
      body: {
        'status': 'confirmed',
        'notes': 'Changed after confirming',
        'lines': [
          {
            'itemId': itemId,
            'itemName': 'Widget',
            'quantityOrdered': qty,
            'unitPrice': 4.5,
          },
        ],
      },
    );

    test('a confirmed order nobody has billed can be changed', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, _) = await confirmed(s, id);

      final response = await edit(s, orderId, id);

      expect(response.statusCode, 200);
      expect(response.json['salesOrder']['status'], 'confirmed');
      expect(response.json['salesOrder']['lines'][0]['quantityOrdered'], 5);
      expect(response.json['salesOrder']['notes'], 'Changed after confirming');
      expect(await quantityOf(s, id), 10, reason: 'an edit moves no stock');
    });

    test('an edit still cannot promise stock that is not there', () async {
      final s = await admin();
      final id = await item(s, quantity: 4);
      final (orderId, _) = await confirmed(s, id);

      final response = await edit(s, orderId, id, qty: 6);

      expect(response.statusCode, 400);
      expect(
        response.json['error']['message'],
        contains('Widget has only 4 in stock (6 ordered)'),
      );
    });

    test('once billed it is locked, and says by what', () async {
      final s = await admin();
      final id = await item(s, quantity: 10);
      final (orderId, _) = await confirmed(s, id);
      final receipt = await server.post(
        '/documents/receipts',
        accessToken: s.accessToken,
        body: {
          'salesOrderId': orderId,
          'movesStock': true,
          'amountPaid': 4.0,
          'lines': [
            {
              'itemId': id,
              'itemName': 'Widget',
              'quantity': 1,
              'unitPrice': 4.0,
            },
          ],
        },
      );
      final reference = receipt.json['receipt']['reference'] as String;

      final response = await edit(s, orderId, id);

      expect(response.statusCode, 400);
      expect(response.json['error']['message'], contains(reference));
      expect(
        response.json['error']['message'],
        contains('can no longer be edited'),
      );
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
