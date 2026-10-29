import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

/// A sale cancelled before cancelling returned stock, with its invoice left
/// live. Both pages have to say so, or nobody knows to cancel the invoice.
Future<InventoryController> _legacy({double paid = 0}) => seededController(
  salesOrders: [
    seedSalesOrder(
      id: 'so1',
      reference: 'SO-0001',
      status: SalesStatus.cancelled,
      lines: const [
        SalesOrderLine(
          id: 'l1',
          itemId: 'i1',
          itemName: 'Widget',
          quantityOrdered: 4,
          quantityFulfilled: 4,
          unitPrice: 4,
        ),
      ],
    ),
  ],
  invoices: [
    Invoice(
      id: 'inv1',
      reference: 'INV-0001',
      salesOrderId: 'so1',
      customerName: 'A customer',
      amountPaid: paid,
      status: paid > 0 ? InvoiceStatus.partPaid : InvoiceStatus.open,
      movesStock: false,
      lines: const [
        InvoiceLine(
          id: 'il1',
          itemId: 'i1',
          itemName: 'Widget',
          quantity: 4,
          unitPrice: 4,
        ),
      ],
      issuedAt: DateTime(2026, 10, 1),
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  InventoryController controller,
  String location,
) async {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: StockpileApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the invoice says its sale was cancelled', (tester) async {
    await _pump(tester, await _legacy(), '/invoices/inv1');

    expect(find.text('The sale this invoice bills was cancelled'), findsOne);
    expect(find.text('Cancel invoice'), findsOne, reason: 'can still cancel');
  });

  testWidgets('a paid one says to refund first', (tester) async {
    await _pump(tester, await _legacy(paid: 5), '/invoices/inv1');

    expect(find.textContaining('Refund the payment'), findsOne);
    expect(find.text('Cancel invoice'), findsNothing);
  });

  testWidgets('the cancelled sale flags its live invoice', (tester) async {
    await _pump(tester, await _legacy(), '/sales-orders/so1');

    expect(find.text('Invoice still live'), findsOne);
    expect(find.textContaining('INV-0001 was not'), findsOne);
  });
}
