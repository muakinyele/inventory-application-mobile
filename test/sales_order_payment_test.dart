import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

/// Ten ordered at 60, [sent] of them gone out.
SalesOrder _sale({int sent = 4, SalesStatus? status}) => seedSalesOrder(
  id: 'so1',
  reference: 'SO-0021',
  customerName: 'Ada Nwosu',
  status: status ?? (sent > 0 ? SalesStatus.partial : SalesStatus.confirmed),
  lines: [
    SalesOrderLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantityOrdered: 10,
      quantityFulfilled: sent,
      unitPrice: 60,
    ),
  ],
);

const _boltLine = ReceiptLine(
  id: 'rl1',
  itemId: 'i1',
  itemName: 'Bolt',
  quantity: 1,
  unitPrice: 60,
);

Invoice _invoice({double paid = 0}) => Invoice(
  id: 'inv1',
  reference: 'INV-0042',
  salesOrderId: 'so1',
  customerName: 'Ada Nwosu',
  status: paid > 0 ? InvoiceStatus.partPaid : InvoiceStatus.open,
  amountPaid: paid,
  movesStock: false,
  lines: const [
    InvoiceLine(
      id: 'il1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantity: 3,
      unitPrice: 60,
    ),
  ],
  issuedAt: DateTime(2026, 10, 1),
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('where a sale stands for money', () {
    test(
      'paid now and pay later are added up without double counting',
      () async {
        // Ten ordered at 60. One billed at the counter (60, paid), three on an
        // invoice (180) with 100 paid against it — recorded as a receipt that
        // carries both, so neither paid nor billed twice.
        final c = await seededController(
          salesOrders: [_sale()],
          invoices: [_invoice(paid: 100)],
          receipts: [
            seedReceipt(
              id: 'r1',
              salesOrderId: 'so1',
              amountPaid: 60,
              lines: const [_boltLine],
            ),
            seedReceipt(
              id: 'r2',
              reference: 'RC-0002',
              salesOrderId: 'so1',
              invoiceId: 'inv1',
              amountPaid: 100,
              lines: const [_boltLine],
            ),
          ],
        );

        final money = c.paymentsForSalesOrder('so1');

        expect(money.paid, 160, reason: 'not 260: the invoice payment once');
        expect(money.owed, 80);
        expect(money.unbilled, 6 * 60, reason: 'four of ten are billed');
        expect(money.collectable?.reference, 'INV-0042');
      },
    );

    test('nothing billed yet: the whole order is still to bill', () async {
      final c = await seededController(salesOrders: [_sale(sent: 0)]);

      final money = c.paymentsForSalesOrder('so1');

      expect(money.paid, 0);
      expect(money.unbilled, 600);
      expect(money.collectable, isNull);
    });

    test(
      'a voided receipt and a cancelled invoice count for nothing',
      () async {
        final c = await seededController(
          salesOrders: [_sale()],
          invoices: [
            Invoice(
              id: 'inv2',
              reference: 'INV-0043',
              salesOrderId: 'so1',
              status: InvoiceStatus.cancelled,
              lines: const [],
              issuedAt: DateTime(2026, 10, 1),
              createdAt: DateTime(2026, 10, 1),
              updatedAt: DateTime(2026, 10, 1),
            ),
          ],
          receipts: [
            seedReceipt(
              id: 'r1',
              salesOrderId: 'so1',
              amountPaid: 60,
              status: ReceiptStatus.voided,
              lines: const [_boltLine],
            ),
          ],
        );

        final money = c.paymentsForSalesOrder('so1');
        expect(money.paid, 0);
        expect(money.owed, 0);
        expect(money.unbilled, 600);
      },
    );
  });

  group('the payment section', () {
    Future<void> pump(
      WidgetTester tester,
      InventoryController controller,
      String location,
    ) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: controller,
          child: StockpileApp(initialLocation: location),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers paid now and pay later once confirmed', (tester) async {
      await pump(
        tester,
        await seededController(salesOrders: [_sale(sent: 0)]),
        '/sales-orders/so1',
      );

      expect(find.text('Payment'), findsOne);
      expect(find.text('Paid now'), findsOne);
      expect(find.text('Pay later'), findsOne);
      expect(find.text('Issue receipt'), findsOne);
      expect(find.text('Create invoice'), findsOne);
    });

    testWidgets('a draft says to confirm it first', (tester) async {
      await pump(
        tester,
        await seededController(
          salesOrders: [_sale(sent: 0, status: SalesStatus.draft)],
        ),
        '/sales-orders/so1',
      );

      expect(find.text('Paid now'), findsNothing);
      expect(find.textContaining('Confirm the sale first'), findsOne);
    });

    testWidgets('once all of it is billed, nothing more is offered', (
      tester,
    ) async {
      await pump(
        tester,
        await seededController(
          salesOrders: [_sale(sent: 10, status: SalesStatus.fulfilled)],
          receipts: [
            seedReceipt(
              id: 'r1',
              salesOrderId: 'so1',
              amountPaid: 600,
              lines: const [
                ReceiptLine(
                  id: 'rl1',
                  itemId: 'i1',
                  itemName: 'Bolt',
                  quantity: 10,
                  unitPrice: 60,
                ),
              ],
            ),
          ],
        ),
        '/sales-orders/so1',
      );

      expect(find.text('Paid now'), findsNothing);
      expect(find.textContaining('Everything on this order'), findsOne);
    });

    testWidgets('record payment goes straight to the payment form', (
      tester,
    ) async {
      await pump(
        tester,
        await seededController(salesOrders: [_sale()], invoices: [_invoice()]),
        '/sales-orders/so1',
      );

      final button = find.textContaining('Record payment on INV-0042');
      expect(button, findsOne);
      await tester.tap(button);
      await tester.pumpAndSettle();

      // The invoice page, with its payment dialog already open.
      expect(find.text('Record payment'), findsWidgets);
      expect(find.byType(AlertDialog), findsOne);
    });

    testWidgets('fits a phone screen', (tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: await seededController(salesOrders: [_sale()]),
          child: const StockpileApp(initialLocation: '/sales-orders/so1'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paid now'), findsOne);
      expect(tester.takeException(), isNull);
    });
  });
}
