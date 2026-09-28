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
      final id = await item(s, quantity: 0);
      final (orderId, lineId) = await confirmed(s, id, ordered: 5);

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

      await server.patch(
        '/documents/sales-orders/$orderId',
        accessToken: s.accessToken,
        body: {
          'status': 'cancelled',
          'lines': [
            {'itemId': id, 'itemName': 'Widget', 'quantityOrdered': 4},
          ],
        },
      );

      // Re-read the line id: saving replaces the lines, so the old one is gone
      // and a 400 for that reason would prove nothing about cancellation.
      final reread = await server.get(
        '/documents/sales-orders/$orderId',
        accessToken: s.accessToken,
      );
      final lineId = reread.json['salesOrder']['lines'][0]['id'] as String;

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
