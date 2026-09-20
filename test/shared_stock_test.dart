import 'dart:convert';

import 'package:flutter/material.dart' hide Durations;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/inventory_status_banner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/inventory_api.dart';
import 'package:stockpile/data/snapshot.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

/// Stands in for the server. These assert what the controller does with the
/// answer, not what the server computes — that is covered on the other side.
class _Server {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];

  /// The last body sent to each route. `bodies.last` is not reliable once a
  /// write triggers a follow-up — saving an item also writes the picker lists.
  final lastBodyFor = <String, Map<String, dynamic>>{};

  /// The count the fake currently believes. Changed between calls to stage a
  /// second device having moved it.
  int quantity = 10;

  /// What the fake server has recorded against the one invoice it knows about.
  double invoicePaid = 0;

  /// Whether the erase actually reached the server.
  bool erased = false;

  bool conflictNext = false;
  bool failNext = false;

  http.Client client() => MockClient((request) async {
    final route = '${request.method} ${request.url.path}';
    calls.add(route);
    if (request.body.isNotEmpty) {
      final parsed = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(parsed);
      lastBodyFor[route] = parsed;
    }

    if (failNext) {
      failNext = false;
      return http.Response('{}', 500);
    }

    if (route.endsWith('/stock/adjust')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (conflictNext) {
        conflictNext = false;
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'stock_conflict',
              'message':
                  'This item now reads $quantity, not '
                  '${body['expectedQuantity']}.',
            },
          }),
          409,
          headers: {'content-type': 'application/json'},
        );
      }
      quantity += (body['delta'] as num).toInt();
      return _ok({
        'item': _item(quantity: quantity),
        'movement': {
          'id': 'm1',
          'itemId': 'i1',
          'itemName': 'Widget',
          'kind': body['kind'],
          'before': (body['expectedQuantity'] as num).toInt(),
          'after': quantity,
          'note': body['note'],
          'actor': 'u1',
          'documentId': null,
          'at': '2026-09-15T10:00:00.000Z',
        },
      });
    }

    if (route == 'POST /api/documents/invoices') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final lines = (body['lines'] as List).cast<Map<String, dynamic>>();
      if (body['movesStock'] == true) {
        for (final line in lines) {
          quantity -= (line['quantity'] as num).toInt();
        }
      }
      return _ok({
        'invoice': {
          ...body,
          // The server mints both, whatever the client sent.
          'id': 'inv-server-1',
          'reference': 'INV-0042',
          'lines': lines,
        },
      });
    }

    if (route == 'POST /api/documents/receipts') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final lines = (body['lines'] as List).cast<Map<String, dynamic>>();
      if (body['movesStock'] == true) {
        for (final line in lines) {
          quantity -= (line['quantity'] as num).toInt();
        }
      }
      return _ok({
        'receipt': {
          ...body,
          'id': 'rcp-server-1',
          'reference': 'RC-0007',
          'status': 'issued',
          'lines': lines,
        },
      });
    }

    if (route.startsWith('POST /api/documents/receipts/') &&
        route.endsWith('/void')) {
      // Voiding puts back what the receipt took.
      quantity += 4;
      return _ok({
        'receipt': {
          'id': 'rcp-server-1',
          'reference': 'RC-0007',
          'status': 'voided',
          'movesStock': true,
          'voidReason': 'Wrong item',
          'lines': <Object?>[],
          'issuedAt': '2026-09-15T10:00:00.000Z',
          'createdAt': '2026-09-15T10:00:00.000Z',
          'updatedAt': '2026-09-15T10:05:00.000Z',
        },
      });
    }

    if (route == 'POST /api/documents/purchase-orders') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'purchaseOrder': {
          ...body,
          'id': 'po-server-1',
          'reference': 'PO-0011',
          // Placed, not a draft: only an ordered or partly-received order can
          // be received against, which is what makes the next test reachable.
          'status': 'ordered',
          'lines': [
            for (final line in (body['lines'] as List))
              {...(line as Map<String, dynamic>), 'id': 'line-1'},
          ],
        },
      });
    }

    if (route.startsWith('POST /api/documents/purchase-orders/') &&
        route.endsWith('/receive')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final received = (body['received'] as Map).cast<String, dynamic>();
      // The server clamps to what is outstanding — here, 6 of a 10-line order
      // even when more is asked for.
      final asked = (received['line-1'] as num).toInt();
      final accepted = asked > 6 ? 6 : asked;
      quantity += accepted;
      return _ok({
        'purchaseOrder': {
          'id': 'po-server-1',
          'reference': 'PO-0011',
          'status': accepted >= 10 ? 'received' : 'partial',
          'lines': [
            {
              'id': 'line-1',
              'itemId': 'i1',
              'itemName': 'Widget',
              'quantityOrdered': 10,
              'quantityReceived': accepted,
              'unitCost': 1.0,
              'position': 0,
            },
          ],
          'createdAt': '2026-09-15T10:00:00.000Z',
          'updatedAt': '2026-09-15T10:05:00.000Z',
        },
      });
    }

    if (route == 'POST /api/documents/sales-orders') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'salesOrder': {
          ...body,
          'id': 'so-server-1',
          'reference': 'SO-0021',
          'status': 'confirmed',
          'lines': [
            for (final line in (body['lines'] as List))
              {...(line as Map<String, dynamic>), 'id': 'so-line-1'},
          ],
        },
      });
    }

    if (route.startsWith('POST /api/documents/sales-orders/') &&
        route.endsWith('/despatch')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final asked = ((body['sent'] as Map)['so-line-1'] as num).toInt();
      // Clamped by the shelf, which is the constraint a delivery does not
      // have: only what is actually there can go.
      final went = asked > quantity ? quantity : asked;
      quantity -= went;
      return _ok({
        'salesOrder': {
          'id': 'so-server-1',
          'reference': 'SO-0021',
          'status': went >= 20 ? 'fulfilled' : 'partial',
          'lines': [
            {
              'id': 'so-line-1',
              'itemId': 'i1',
              'itemName': 'Widget',
              'quantityOrdered': 20,
              'quantityFulfilled': went,
              'unitPrice': 4.0,
              'costOfGoods': 0.0,
              'position': 0,
            },
          ],
          'createdAt': '2026-09-15T10:00:00.000Z',
          'updatedAt': '2026-09-15T10:05:00.000Z',
        },
      });
    }

    if (route.startsWith('POST /api/documents/receipts/') &&
        route.endsWith('/refund')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final asked = ((body['returned'] as Map)['l1'] as num).toInt();
      // Capped at what is still kept — four were bought.
      final back = asked > 4 ? 4 : asked;
      if (body['restock'] == true) quantity += back;
      return _ok({
        'receipt': {
          'id': 'rcp-server-1',
          'reference': 'RC-0007',
          'status': back >= 4 ? 'refunded' : 'partRefunded',
          'movesStock': true,
          'lines': [
            {
              'id': 'l1',
              'itemId': 'i1',
              'itemName': 'Widget',
              'quantity': 4,
              'unitPrice': 3.0,
              'quantityRefunded': back,
              'position': 0,
            },
          ],
          'issuedAt': '2026-09-15T10:00:00.000Z',
          'createdAt': '2026-09-15T10:00:00.000Z',
          'updatedAt': '2026-09-15T10:10:00.000Z',
        },
      });
    }

    if (route == 'POST /api/inventory/items') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'item': {..._item(quantity: 0), ...body, 'id': 'item-server-1'},
      });
    }

    if (route.startsWith('PATCH /api/inventory/items/')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'item': {..._item(quantity: quantity), ...body, 'id': 'i1'},
      });
    }

    if (route == 'POST /api/inventory/suppliers') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'supplier': {
          ...body,
          'id': (body['id'] as String?)?.isNotEmpty == true
              ? body['id']
              : 'sup-server-1',
        },
      });
    }

    if (route.startsWith('POST /api/documents/invoices/') &&
        route.endsWith('/payments')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      // A 40.00 invoice. The server caps at the balance and says what it took.
      final balance = 40.0 - invoicePaid;
      final asked = (body['amount'] as num).toDouble();
      final applied = asked > balance ? balance : asked;
      invoicePaid += applied;
      return _ok({
        'invoice': {
          'id': 'inv-server-1',
          'reference': 'INV-0042',
          'status': (40.0 - invoicePaid) < 0.005 ? 'paid' : 'partPaid',
          'amountPaid': invoicePaid,
          'lines': <Object?>[],
          'issuedAt': '2026-09-16T10:00:00.000Z',
          'createdAt': '2026-09-16T10:00:00.000Z',
          'updatedAt': '2026-09-16T10:05:00.000Z',
        },
        'applied': applied,
      });
    }

    if (route.startsWith('PATCH /api/documents/sales-orders/')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({
        'salesOrder': {
          ...body,
          'id': 'so-server-1',
          'reference': 'SO-0021',
          'lines': body['lines'] ?? <Object?>[],
        },
      });
    }

    if (route == 'PATCH /api/inventory/preferences') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _ok({'preferences': body['preferences']});
    }

    if (route == 'PUT /api/inventory/categories') {
      return _ok({'categories': <Object?>[]});
    }

    if (route.startsWith('PUT /api/inventory/lookups/')) {
      return _ok({'lookups': <Object?>[]});
    }

    if (route == 'DELETE /api/inventory') {
      erased = true;
      quantity = 0;
      return http.Response('', 204);
    }

    if (route == 'GET /api/inventory/items') {
      // After an erase the server has nothing, and a reload has to see that.
      if (erased) return _ok({'items': <Object?>[], 'total': 0});
      return _ok({
        'items': [_item(quantity: quantity)],
        'total': 1,
      });
    }

    if (route == 'GET /api/inventory/movements') {
      return _ok({'movements': <Object?>[]});
    }

    if (route.contains('/inventory/items/')) {
      return _ok({
        'item': _item(quantity: quantity),
        'stock': [
          {'itemId': 'i1', 'location': 'Main', 'quantity': quantity},
        ],
      });
    }

    return _ok({});
  });

  http.Response _ok(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  Map<String, dynamic> _item({required int quantity}) => {
    'id': 'i1',
    'name': 'Widget',
    'sku': '',
    'barcode': '',
    'category': '',
    'location': 'Main',
    'quantity': quantity,
    'reorderLevel': 0,
    'unit': 'pcs',
    'unitCost': 0,
    'retailerPrice': 0,
    'distributorPrice': 0,
    'supplier': '',
    'supplierId': null,
    'unitsPerPack': 1,
    'notes': '',
    'photo': null,
    'createdAt': '2026-09-01T10:00:00.000Z',
    'updatedAt': '2026-09-01T10:00:00.000Z',
  };
}

Future<InventoryController> _controller(_Server server) async {
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
    client: server.client(),
  );
  await auth.restore();

  final snapshot = Snapshot(
    items: [
      Item(
        id: 'i1',
        name: 'Widget',
        location: 'Main',
        quantity: 10,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    ],
    movements: const [],
    settings: const AppSettings(),
  );
  return InventoryController(InventoryApi(auth), snapshot);
}

Future<void> _pumpBanner(
  WidgetTester tester,
  InventoryController controller,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<InventoryController>.value(
      value: controller,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: InventoryStatusBanner()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('against a shared inventory', () {
    test('the server owns the arithmetic', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.adjustStock('i1', -3, note: 'Sold');

      // What this device believed, sent so the server can refuse if it moved.
      expect(server.bodies.single['expectedQuantity'], 10);
      expect(server.bodies.single['delta'], -3);
      // And the count that comes back is the server's, not one computed here.
      expect(controller.byId('i1')!.quantity, 7);
    });

    test('the movement the server recorded is the one shown', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.adjustStock('i1', -3, note: 'Sold');

      expect(controller.movements.first.before, 10);
      expect(controller.movements.first.after, 7);
      expect(controller.movements.first.note, 'Sold');
    });

    test('a stocktake sends the difference, not the total', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.setStock('i1', 4);

      expect(server.bodies.single['delta'], -6);
      expect(server.bodies.single['expectedQuantity'], 10);
      expect(controller.byId('i1')!.quantity, 4);
    });

    test('a refused write leaves the server\'s count showing', () async {
      // Somebody else sold the last of it. Re-applying the user's change
      // blindly is the overwrite the refusal exists to prevent, so the screen
      // has to show what is actually there.
      final server = _Server()
        ..conflictNext = true
        ..quantity = 2;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -5);

      expect(controller.stockConflict, isNotNull);
      expect(controller.stockConflict, contains('now reads 2'));
      expect(controller.byId('i1')!.quantity, 2, reason: 're-read, not 5');
    });

    test('a later success clears the conflict', () async {
      final server = _Server()..conflictNext = true;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -1);
      expect(controller.stockConflict, isNotNull);

      await controller.adjustStock('i1', -1);
      expect(controller.stockConflict, isNull);
    });

    test('a transport failure is reported, not swallowed', () async {
      final server = _Server()..failNext = true;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -1);

      expect(controller.lastWriteError, isNotNull);
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'nothing was applied locally',
      );
    });

    test('an invoice is raised by the server, not numbered here', () async {
      final server = _Server();
      final controller = await _controller(server);

      final invoice = await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 3,
            unitPrice: 5,
          ),
        ],
      );

      // Sent blank: allocating a reference locally would let two devices raise
      // the same invoice number.
      final sent = server.bodies.last;
      expect(sent['id'], '');
      expect(sent['reference'], '');

      expect(invoice, isNotNull);
      expect(invoice!.reference, 'INV-0042');
      expect(invoice.id, 'inv-server-1');
      expect(controller.invoices.first.reference, 'INV-0042');
    });

    test('the stock it took comes back from the server', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 5,
          ),
        ],
      );

      // Re-read rather than computed here: the server is the only party that
      // can see what other devices have already sold.
      expect(controller.byId('i1')!.quantity, 6);
      expect(server.calls, contains('GET /api/inventory/items'));
    });

    test('cost of goods is captured at the moment of sale', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 2,
            unitPrice: 5,
          ),
        ],
      );

      final line =
          (server.bodies.last['lines'] as List).first as Map<String, dynamic>;
      expect(line.containsKey('costOfGoods'), isTrue);
    });

    test('a failed invoice is reported and raises nothing', () async {
      final server = _Server()..failNext = true;
      final controller = await _controller(server);

      final invoice = await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 1,
            unitPrice: 5,
          ),
        ],
      );

      expect(invoice, isNull);
      expect(controller.lastWriteError, isNotNull);
      expect(controller.invoices, isEmpty);
      expect(controller.byId('i1')!.quantity, 10, reason: 'stock untouched');
    });

    test('a counter sale is issued by the server', () async {
      final server = _Server();
      final controller = await _controller(server);

      final receipt = await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 3,
          ),
        ],
      );

      expect(receipt, isNotNull);
      expect(receipt!.reference, 'RC-0007');
      expect(
        server.bodies.last['reference'],
        '',
        reason: 'the server numbers it',
      );
      expect(
        controller.byId('i1')!.quantity,
        6,
        reason: 're-read from the server',
      );
    });

    test('voiding returns the stock the receipt took', () async {
      final server = _Server();
      final controller = await _controller(server);

      final receipt = (await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 3,
          ),
        ],
      ))!;
      expect(controller.byId('i1')!.quantity, 6);

      final voided = await controller.voidReceipt(
        receipt.id,
        reason: 'Wrong item',
      );

      expect(voided, isTrue);
      expect(controller.receiptById(receipt.id)!.status, ReceiptStatus.voided);
      expect(controller.byId('i1')!.quantity, 10, reason: 'put back');
    });

    test('a failed sale banks nothing', () async {
      final server = _Server()..failNext = true;
      final controller = await _controller(server);

      final receipt = await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 2,
            unitPrice: 3,
          ),
        ],
      );

      expect(receipt, isNull);
      expect(controller.lastWriteError, isNotNull);
      expect(controller.receipts, isEmpty);
      expect(controller.byId('i1')!.quantity, 10);
    });

    test('an order is numbered by the server and moves no stock', () async {
      final server = _Server();
      final controller = await _controller(server);

      final order = await controller.createPurchaseOrder(
        lines: const [
          PurchaseOrderLine(
            id: '',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 10,
            unitCost: 1,
          ),
        ],
      );

      expect(order.reference, 'PO-0011');
      expect(server.bodies.last['reference'], '');
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'ordering is not receiving',
      );
    });

    test('a delivery books in what the server accepted', () async {
      // Not what was asked for: the server clamps each line to what is still
      // outstanding, and this device may be working from an order somebody
      // else has already received against.
      final server = _Server();
      final controller = await _controller(server);

      final order = await controller.createPurchaseOrder(
        lines: const [
          PurchaseOrderLine(
            id: '',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 10,
            unitCost: 1,
          ),
        ],
      );

      final accepted = await controller.receivePurchaseOrder(order.id, {
        'line-1': 9,
      });

      expect(
        accepted,
        6,
        reason: 'the server accepted six, not the nine asked',
      );
      expect(controller.byId('i1')!.quantity, 16);
      expect(
        controller.purchaseOrderById(order.id)!.status,
        PurchaseStatus.partial,
      );
    });

    test('a despatch reports what actually left the shelf', () async {
      // Asked for twenty, only ten on hand. The server sends what it has and
      // says so; counting the request would report a despatch that did not
      // happen.
      final server = _Server();
      final controller = await _controller(server);

      final order = await controller.createSalesOrder(
        lines: const [
          SalesOrderLine(
            id: '',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 20,
            unitPrice: 4,
          ),
        ],
      );
      expect(order.reference, 'SO-0021');
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'confirming moves nothing',
      );

      final despatched = await controller.fulfilSalesOrder(order.id, {
        'so-line-1': 20,
      });

      expect(despatched, 10, reason: 'only what was on the shelf');
      expect(controller.byId('i1')!.quantity, 0);
      expect(controller.salesOrderById(order.id)!.status, SalesStatus.partial);
    });

    test('a return puts the goods back and settles the receipt', () async {
      final server = _Server();
      final controller = await _controller(server);

      final receipt = (await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 3,
          ),
        ],
      ))!;
      expect(controller.byId('i1')!.quantity, 6);

      final lines = await controller.refundReceipt(receipt.id, {'l1': 4});

      expect(lines, 1, reason: 'one line had something come back');
      expect(
        controller.receiptById(receipt.id)!.status,
        ReceiptStatus.refunded,
      );
      expect(controller.byId('i1')!.quantity, 10);
    });

    test('broken goods are refunded without going back on', () async {
      // Stock and money part company: the customer is repaid, the shelf is
      // not replenished.
      final server = _Server();
      final controller = await _controller(server);

      final receipt = (await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 3,
          ),
        ],
      ))!;
      expect(controller.byId('i1')!.quantity, 6);

      await controller.refundReceipt(receipt.id, {'l1': 4}, restock: false);

      expect(
        controller.receiptById(receipt.id)!.status,
        ReceiptStatus.refunded,
      );
      expect(controller.byId('i1')!.quantity, 6, reason: 'shelf unchanged');
    });

    test('asking for more than was bought is not a refund', () async {
      // The server caps at what is still kept, so the count has to come from
      // the answer. Counting the request would report a return that never
      // happened.
      final server = _Server();
      final controller = await _controller(server);

      final receipt = (await controller.issueReceipt(
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 3,
          ),
        ],
      ))!;

      await controller.refundReceipt(receipt.id, {'l1': 99});

      expect(
        controller.receiptById(receipt.id)!.lines.single.quantityRefunded,
        4,
        reason: 'only the four actually bought',
      );
      expect(controller.byId('i1')!.quantity, 10);
    });

    test('a new item is added to the shared catalogue', () async {
      final server = _Server();
      final controller = await _controller(server);

      final saved = await controller.createItem(
        Item(
          id: '',
          name: 'Bolt',
          quantity: 12,
          location: 'Main',
          createdAt: DateTime.utc(2026, 9, 15),
          updatedAt: DateTime.utc(2026, 9, 15),
        ),
      );

      expect(saved.id, 'item-server-1', reason: 'the server mints the id');
      expect(controller.items.any((i) => i.id == 'item-server-1'), isTrue);
      // The opening count goes with it, so the server books it in as stock
      // arriving rather than it appearing from nowhere elsewhere.
      expect(server.lastBodyFor['POST /api/inventory/items']!['quantity'], 12);
    });

    test('an edit never carries a quantity', () async {
      // Counts move only through an adjustment, so each change has a movement
      // behind it. A quantity here would be silently dropped.
      final server = _Server();
      final controller = await _controller(server);

      await controller.updateItem(
        'i1',
        Item(
          id: 'i1',
          name: 'Widget renamed',
          quantity: 999,
          createdAt: DateTime.utc(2026, 9, 1),
          updatedAt: DateTime.utc(2026, 9, 15),
        ),
      );

      expect(
        server.lastBodyFor['PATCH /api/inventory/items/i1']!.containsKey(
          'quantity',
        ),
        isFalse,
      );
      expect(controller.byId('i1')!.name, 'Widget renamed');
    });

    test('a supplier edit keeps the id it was given', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.updateSupplier(
        'sup-1',
        Supplier(
          id: '',
          name: 'Acme',
          createdAt: DateTime.utc(2026, 9, 1),
          updatedAt: DateTime.utc(2026, 9, 15),
        ),
      );

      // The editor builds a draft from the form and has no id in it; the
      // caller's id is what identifies the row.
      expect(
        server.lastBodyFor['POST /api/inventory/suppliers']!['id'],
        'sup-1',
      );
      expect(controller.suppliers.single.name, 'Acme');
    });

    testWidgets('a refused write is said out loud', (tester) async {
      // Until now every refusal path worked and none of them was visible: a
      // rejected change looked exactly like nothing happening, which is worse
      // than an error, because the user has a number in their head.
      final server = _Server()
        ..conflictNext = true
        ..quantity = 2;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -5);
      await _pumpBanner(tester, controller);

      expect(find.textContaining('now reads 2'), findsOneWidget);
    });

    testWidgets('a failed load says so and offers a retry', (tester) async {
      final server = _Server()..failNext = true;
      final controller = await _controller(server);

      await controller.reload();
      expect(controller.load, InventoryLoad.failed);

      await _pumpBanner(tester, controller);

      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a healthy load shows no banner', (tester) async {
      final controller = await _controller(_Server());

      await controller.reload();
      await _pumpBanner(tester, controller);

      expect(controller.load, InventoryLoad.ready);
      expect(find.textContaining('could not'), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    test('a failed reload keeps what was already on screen', () async {
      // Half a catalogue is still worth showing while the strip says the
      // refresh did not work. Blanking it would look like a workspace with
      // nothing in it.
      final server = _Server();
      final controller = await _controller(server);
      expect(controller.items, isNotEmpty);

      server.failNext = true;
      await controller.reload();

      expect(controller.load, InventoryLoad.failed);
      expect(controller.items, isNotEmpty, reason: 'not blanked');
    });

    test('signing out leaves nothing of the workspace behind', () async {
      // A shared terminal: whoever signs in next must not find the last
      // person's catalogue on screen.
      final controller = await _controller(_Server());
      await controller.reload();
      expect(controller.items, isNotEmpty);

      controller.forgetSharedData();

      expect(controller.items, isEmpty);
      expect(controller.load, InventoryLoad.idle);
    });

    test('a payment is added by the server, not computed here', () async {
      // Another till may have paid against the same invoice since this screen
      // was opened, so the balance on it is already stale. What was taken is
      // the server's answer.
      final server = _Server();
      final controller = await _controller(server);

      final invoice = (await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 10,
          ),
        ],
      ))!;

      final receipt = await controller.payInvoice(invoice.id, 25);

      expect(
        server
            .lastBodyFor['POST /api/documents/invoices/${invoice.id}/payments']!['amount'],
        25,
      );
      expect(controller.invoiceById(invoice.id)!.amountPaid, 25);
      expect(
        controller.invoiceById(invoice.id)!.status,
        InvoiceStatus.partPaid,
      );
      // The receipt documents the payment and moves no stock: the goods left
      // when the invoice was raised.
      expect(receipt, isNotNull);
      expect(receipt!.movesStock, isFalse);
      expect(receipt.amountPaid, 25);
    });

    test('overpaying takes only the balance', () async {
      final server = _Server();
      final controller = await _controller(server);

      final invoice = (await controller.issueInvoice(
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 4,
            unitPrice: 10,
          ),
        ],
      ))!;

      final receipt = await controller.payInvoice(invoice.id, 100);

      expect(
        receipt!.amountPaid,
        40,
        reason: 'the rest is change, not revenue',
      );
      expect(controller.invoiceById(invoice.id)!.status, InvoiceStatus.paid);
    });

    test('a status change reaches the server', () async {
      // Confirming, cancelling and closing all go through one helper. While it
      // wrote only to the device, the change looked right until the next load
      // and was never true for anybody else.
      //
      // Cancelling is the one used here because it has no precondition on the
      // current status, so the test is about the write-through rather than
      // about which transitions are legal.
      final server = _Server();
      final controller = await _controller(server);

      final order = await controller.createSalesOrder(
        lines: const [
          SalesOrderLine(
            id: '',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 2,
            unitPrice: 4,
          ),
        ],
      );
      server.calls.clear();

      controller.cancelSalesOrder(order.id);
      await Future<void>.delayed(Duration.zero);

      expect(
        server.calls.any(
          (c) => c.startsWith('PATCH /api/documents/sales-orders/'),
        ),
        isTrue,
        reason: 'the status change was never sent',
      );
    });

    test('settings are saved to the workspace, not the device', () async {
      // The company name on an invoice has to be the one everybody prints.
      final server = _Server();
      final controller = await _controller(server);

      await controller.updateSettings(
        controller.settings.copyWith(companyName: 'Chedra Olympas'),
      );

      final sent =
          server.lastBodyFor['PATCH /api/inventory/preferences']!['preferences']
              as Map<String, dynamic>;
      expect(sent['companyName'], 'Chedra Olympas');
    });

    test('erasing leaves the pickers as the server has them', () async {
      // AppSettings() carries default categories, locations and units. Reset
      // to that after an erase, the pickers would show a set the server does
      // not have — and the next save would write those defaults back, undoing
      // part of what was erased.
      final server = _Server();
      final controller = await _controller(server);

      await controller.eraseAll();

      expect(
        server.calls,
        contains('GET /api/inventory/categories'),
        reason: 'the pickers were assumed rather than re-read',
      );
      expect(controller.settings.categories, isEmpty);
    });

    test('erasing reaches the server, not just the screen', () async {
      // It cleared the lists and wrote to a local database nothing reads, so
      // everything came back on the next load — and none of it had ever left
      // anybody else's screen.
      final server = _Server();
      final controller = await _controller(server);
      expect(controller.items, isNotEmpty);

      await controller.eraseAll();

      expect(server.erased, isTrue, reason: 'the server was never asked');
      expect(controller.items, isEmpty);
      expect(controller.movements, isEmpty);
    });

    test('a failed erase leaves the catalogue where it is', () async {
      // Showing an empty catalogue the server still holds is exactly the
      // confusion this is meant to end.
      final server = _Server()..failNext = true;
      final controller = await _controller(server);
      final before = controller.items.length;

      await controller.eraseAll();

      expect(controller.items.length, before);
      expect(controller.lastWriteError, isNotNull);
    });

    test('nothing is shown before the server has agreed to it', () async {
      // The on-device path updates the screen first and persists after, which
      // is right when this device is the only writer. Here a second device may
      // already have sold the last of it.
      final server = _Server();
      final controller = await _controller(server);

      final pending = controller.adjustStock('i1', -3);
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'still the old count while the request is in flight',
      );

      await pending;
      expect(controller.byId('i1')!.quantity, 7);
    });

    // ------------------------------------------------------------------
    // Categories
    //
    // THE DEFECT THESE EXIST FOR: the three category mutations rebuilt
    // `_settings` and notified, and never called the server. The list is
    // loaded from `GET /inventory/categories` at startup, so a delete or a
    // rename reappeared on the next load — reported as "the category is still
    // not deleting and not updating". Every test here asserts that the write
    // LEFT THE DEVICE, because asserting on `controller.settings` alone is
    // what passed throughout the life of the bug.
    // ------------------------------------------------------------------

    test('adding a category reaches the server', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.addCategory('Fasteners', 3);

      expect(
        server.calls,
        contains('PUT /api/inventory/categories'),
        reason: 'the category list was never sent',
      );
      final sent = server.lastBodyFor['PUT /api/inventory/categories']!;
      expect(
        (sent['categories'] as List).map((c) => (c as Map)['name']),
        contains('Fasteners'),
      );
    });

    test('renaming a category reaches the server', () async {
      final server = _Server();
      final controller = await _controller(server);
      await controller.addCategory('Parts', 1);
      server.calls.clear();

      await controller.renameCategory('Parts', 'Hardware', 2);

      final sent = server.lastBodyFor['PUT /api/inventory/categories']!;
      final names = (sent['categories'] as List)
          .map((c) => (c as Map)['name'])
          .toList();
      expect(names, contains('Hardware'));
      expect(names, isNot(contains('Parts')));
    });

    test('deleting a category reaches the server', () async {
      final server = _Server();
      final controller = await _controller(server);
      await controller.addCategory('Parts', 1);
      server.calls.clear();

      await controller.deleteCategory('Parts');

      expect(server.calls, contains('PUT /api/inventory/categories'));
      final sent = server.lastBodyFor['PUT /api/inventory/categories']!;
      expect(
        (sent['categories'] as List).map((c) => (c as Map)['name']),
        isNot(contains('Parts')),
      );
    });

    test(
      'renaming rewrites the items that referenced it, on the server too',
      () async {
        // Items carry their category by NAME and the server's category write
        // only touches the category table, so an item left saying "Parts" after
        // the rename is an item filed under a category that no longer exists.
        final server = _Server();
        final controller = await _controller(server);
        await controller.updateItem(
          'i1',
          controller.byId('i1')!.copyWith(category: 'Parts'),
        );
        server.calls.clear();

        await controller.renameCategory('Parts', 'Hardware', 2);

        expect(
          server.calls,
          contains('PATCH /api/inventory/items/i1'),
          reason: 'the item still says Parts on the server',
        );
        expect(controller.byId('i1')!.category, 'Hardware');
      },
    );

    test(
      'deleting clears the category on the server, and keeps the stock',
      () async {
        final server = _Server();
        final controller = await _controller(server);
        await controller.updateItem(
          'i1',
          controller.byId('i1')!.copyWith(category: 'Parts'),
        );
        final quantity = controller.byId('i1')!.quantity;
        server.calls.clear();

        await controller.deleteCategory('Parts');

        expect(server.calls, contains('PATCH /api/inventory/items/i1'));
        expect(controller.byId('i1')!.category, '');
        expect(
          controller.byId('i1')!.quantity,
          quantity,
          reason: 'losing a category must not lose the count',
        );
      },
    );

    test('a category the server refused is put back on the screen', () async {
      // The whole point of reverting. A category that vanishes from the list
      // and is still on the server is the original defect, one reload later.
      final server = _Server();
      final controller = await _controller(server);
      await controller.addCategory('Parts', 1);
      server.failNext = true;

      final deleted = await controller.deleteCategory('Parts');

      expect(deleted, isFalse);
      expect(
        controller.settings.categories,
        contains('Parts'),
        reason: 'the delete failed, so the category is still there',
      );
      expect(controller.lastWriteError, isNotNull);
    });

    test('a rename the server refused leaves the items alone', () async {
      final server = _Server();
      final controller = await _controller(server);
      await controller.updateItem(
        'i1',
        controller.byId('i1')!.copyWith(category: 'Parts'),
      );
      server.failNext = true;

      final renamed = await controller.renameCategory('Parts', 'Hardware', 2);

      expect(renamed, isFalse);
      expect(controller.byId('i1')!.category, 'Parts');
      expect(controller.settings.categories, contains('Parts'));
      expect(controller.settings.categories, isNot(contains('Hardware')));
    });

    test('a successful category write reports no error', () async {
      final server = _Server();
      final controller = await _controller(server);

      final added = await controller.addCategory('Fasteners', 3);

      expect(added, isTrue);
      expect(controller.lastWriteError, isNull);
    });
  });
}
