import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/data/invoice_document.dart';
import 'package:stockpile/data/sales_order_document.dart';
import 'package:stockpile/data/snapshot.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'fake_inventory_server.dart';
import 'support.dart';

Item _item(String id, String name, int quantity) => Item(
  id: id,
  name: name,
  quantity: quantity,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

SalesOrderLine _line(String itemId, String name, int qty, {int sent = 0}) =>
    SalesOrderLine(
      id: 'l-$itemId',
      itemId: itemId,
      itemName: name,
      quantityOrdered: qty,
      quantityFulfilled: sent,
      unitPrice: 100,
    );

const _bank = AppSettings(
  companyName: 'Chedra Olympas',
  bankName: 'Zenith Bank',
  accountName: 'Chedra Olympas Ltd',
  accountNumber: '1012345678',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a new order cannot promise stock that is not there', () {
    test('each short item is named, with what is there', () async {
      final c = await seededController(
        items: [_item('a', 'Chic Choc', 5), _item('b', 'Malto', 0)],
      );

      final reasons = c.outOfStockReasons([
        _line('a', 'Chic Choc', 6),
        _line('b', 'Malto', 1),
      ]);

      expect(reasons, [
        'Chic Choc has only 5 in stock (6 ordered)',
        'Malto is out of stock (1 ordered)',
      ]);
    });

    test('ordering exactly what is there is allowed', () async {
      final c = await seededController(items: [_item('a', 'Chic Choc', 5)]);
      expect(c.outOfStockReasons([_line('a', 'Chic Choc', 5)]), isEmpty);
    });

    test('a refused confirm goes back to draft and says why', () async {
      final server = FakeInventoryServer();
      final c = InventoryController(
        await fakeInventoryApi(server),
        Snapshot(
          items: const [],
          movements: const [],
          suppliers: const [],
          customers: const [],
          purchaseOrders: const [],
          salesOrders: [
            seedSalesOrder(
              id: 'so1',
              status: SalesStatus.draft,
              lines: [_line('a', 'Chic Choc', 5)],
            ),
          ],
          receipts: const [],
          invoices: const [],
          transfers: const [],
          levels: const {},
          settings: const AppSettings(),
        ),
        loadedDocuments: {...DocumentSet.values},
      );
      server.failNextWrite = true;

      final refused = await c.confirmSalesOrder('so1');

      expect(refused, isNotNull);
      expect(c.salesOrderById('so1')!.status, SalesStatus.draft);
    });
  });

  testWidgets('an out-of-stock order is refused with its reason, and no '
      '"not saved" banner is left behind', (tester) async {
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = await seededController(
      items: [_item('a', 'Chic Choc', 0)],
      salesOrders: [
        seedSalesOrder(
          id: 'so1',
          status: SalesStatus.draft,
          lines: [_line('a', 'Chic Choc', 5)],
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<InventoryController>.value(
        value: c,
        child: const StockpileApp(initialLocation: '/sales-orders/so1/edit'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm sale').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Chic Choc is out of stock'), findsOne);
    expect(c.lastWriteError, isNull);
    expect(c.salesOrderById('so1')!.status, SalesStatus.draft);
  });

  testWidgets('a new order lists each item with the stock it has', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = await seededController(
      items: [_item('a', 'Chic Choc', 5), _item('b', 'Malto', 0)],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<InventoryController>.value(
        value: c,
        child: const StockpileApp(initialLocation: '/sales-orders/new'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add line'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('5 pcs in stock'), findsWidgets);
    expect(find.text('Out of stock'), findsWidgets);

    // Picking one says what the line leaves behind.
    await tester.tap(find.text('Chic Choc').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('5 in stock ·'), findsOne);
  });

  group('a payment whose receipt never saved', () {
    Invoice paidWithoutReceipt() => Invoice(
      id: 'inv4',
      reference: 'INV-0004',
      customerName: 'Muyiwa',
      status: InvoiceStatus.paid,
      amountPaid: 96000,
      movesStock: true,
      lines: const [
        InvoiceLine(
          id: 'x',
          itemId: 'a',
          itemName: 'Large Cabin',
          quantity: 10,
          unitPrice: 9600,
        ),
      ],
      issuedAt: DateTime(2026, 10, 29),
      createdAt: DateTime(2026, 10, 29),
      updatedAt: DateTime(2026, 10, 29),
    );

    test(
      'is found, and issuing it closes the gap without a new payment',
      () async {
        final c = await seededController(invoices: [paidWithoutReceipt()]);
        expect(c.unreceiptedPayment('inv4'), 96000);

        final receipt = await c.issueMissingPaymentReceipt('inv4');

        expect(receipt, isNotNull);
        expect(receipt!.amountPaid, 96000);
        expect(c.unreceiptedPayment('inv4'), 0);
        expect(
          c.invoiceById('inv4')!.amountPaid,
          96000,
          reason: 'no new money',
        );
      },
    );

    testWidgets('the invoice page offers to issue it', (tester) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: await seededController(invoices: [paidWithoutReceipt()]),
          child: const StockpileApp(initialLocation: '/invoices/inv4'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('A payment has no receipt'), findsOne);
      await tester.tap(find.text('Issue the missing receipt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('issued for'), findsOne);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('A payment has no receipt'), findsNothing);
    });
  });

  group('what a sale took, and what is left', () {
    testWidgets('each line says what it took from stock and what remains', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = await seededController(
        items: [_item('a', 'Chic Choc', 0)],
        salesOrders: [
          seedSalesOrder(
            id: 'so1',
            reference: 'SO-0003',
            status: SalesStatus.fulfilled,
            lines: [_line('a', 'Chic Choc', 5, sent: 5)],
          ),
        ],
        movements: [
          Movement(
            id: 'm1',
            itemId: 'a',
            itemName: 'Chic Choc',
            kind: MovementKind.stockOut,
            before: 5,
            after: 0,
            note: 'Receipt RC-0004 for SO-0003',
            documentId: 'so1',
            at: DateTime(2026, 10, 29, 10, 36),
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: c,
          child: const StockpileApp(initialLocation: '/sales-orders/so1'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('5 taken from stock'), findsOne);
      expect(find.text('Stock taken by this sale'), findsOne);
      expect(find.text('5 taken'), findsOne);
      expect(find.text('Balance 0'), findsOne);
    });
  });

  group('bank details', () {
    test('they print on an invoice and a sales order', () async {
      final invoice = await InvoiceDocument(
        Invoice(
          id: 'i1',
          reference: 'INV-0001',
          customerName: 'Ada',
          lines: const [
            InvoiceLine(
              id: 'x',
              itemId: 'a',
              itemName: 'Chic Choc',
              quantity: 1,
              unitPrice: 100,
            ),
          ],
          issuedAt: DateTime(2026, 10, 1),
          createdAt: DateTime(2026, 10, 1),
          updatedAt: DateTime(2026, 10, 1),
        ),
        _bank,
      ).toPdf();
      expect(invoice.length, greaterThan(1000));

      final order = SalesOrderDocument(
        seedSalesOrder(id: 'so1', lines: [_line('a', 'Chic Choc', 1)]),
        _bank,
      );
      expect((await order.toPdf()).length, greaterThan(1000));
      expect(order.summary(), contains('Account number: 1012345678'));
      expect(order.summary(), contains('Bank: Zenith Bank'));
    });

    test('none is printed without an account number', () {
      final order = SalesOrderDocument(
        seedSalesOrder(id: 'so1', lines: [_line('a', 'Chic Choc', 1)]),
        const AppSettings(bankName: 'Zenith Bank'),
      );
      expect(order.summary(), isNot(contains('Pay into')));
    });

    test('they are saved to the workspace with the other settings', () async {
      final server = FakeInventoryServer();
      final c = InventoryController(
        await fakeInventoryApi(server),
        Snapshot.empty,
        loadedDocuments: {...DocumentSet.values},
      );

      await c.updateSettings(_bank);

      expect(server.lastPreferences?['bankName'], 'Zenith Bank');
      expect(server.lastPreferences?['accountName'], 'Chedra Olympas Ltd');
      expect(server.lastPreferences?['accountNumber'], '1012345678');
    });

    testWidgets('the settings section is for administrators only', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: await seededController(),
          child: const StockpileApp(initialLocation: '/settings'),
        ),
      );
      await tester.pumpAndSettle();

      // No signed-in administrator here.
      expect(find.text('Payment details'), findsNothing);
    });
  });
}
