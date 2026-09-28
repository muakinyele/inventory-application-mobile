import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

const _desktop = Size(1400, 2400);

final _receipt = Receipt(
  id: 'r1',
  reference: 'RCP-0042',
  status: ReceiptStatus.issued,
  method: PaymentMethod.cash,
  customerId: 'c1',
  customerName: 'Ada Nwosu',
  lines: const [
    ReceiptLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantity: 2,
      unitPrice: 1500,
    ),
  ],
  amountPaid: 3000,
  issuedAt: DateTime.utc(2026, 9, 3),
  createdAt: DateTime.utc(2026, 9, 3),
  updatedAt: DateTime.utc(2026, 9, 3),
);

Customer _customer() {
  final now = DateTime.utc(2026, 9, 1);
  return Customer(
    id: 'c1',
    name: 'Ada Nwosu',
    contactName: '',
    phone: '+234 802 123 4567',
    email: 'ada@example.com',
    address: '',
    priceTier: PriceTier.retailer,
    notes: '',
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _pump(WidgetTester tester, InventoryController controller) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: const StockpileApp(initialLocation: '/receipts/r1'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('sending a receipt', () {
    testWidgets('the detail page offers viewing, downloading and sending', (
      tester,
    ) async {
      await _pump(
        tester,
        await seededController(receipts: [_receipt], customers: [_customer()]),
      );

      expect(find.text('View'), findsWidgets);
      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
    });

    testWidgets('sending offers the file and the message separately', (
      tester,
    ) async {
      // The distinction the sheet exists to make: a deep link cannot carry an
      // attachment, so "send the PDF" and "send a message about it" are not
      // the same action and must not look like it.
      await _pump(
        tester,
        await seededController(receipts: [_receipt], customers: [_customer()]),
      );

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.text('THE DOCUMENT'), findsOneWidget);
      expect(find.text('A MESSAGE ABOUT IT'), findsOneWidget);
      expect(find.text('Share or save the PDF'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Text message'), findsOneWidget);
    });

    testWidgets('it says the message carries no attachment', (tester) async {
      await _pump(
        tester,
        await seededController(receipts: [_receipt], customers: [_customer()]),
      );

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('To send the PDF itself'),
        findsOneWidget,
        reason: 'otherwise people send an empty WhatsApp and wonder why',
      );
    });

    testWidgets("the customer's own number and address are offered", (
      tester,
    ) async {
      await _pump(
        tester,
        await seededController(receipts: [_receipt], customers: [_customer()]),
      );

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.text('To +234 802 123 4567'), findsOneWidget);
      expect(find.text('To ada@example.com'), findsOneWidget);
    });

    testWidgets('with no customer on file it asks the sender to pick one', (
      tester,
    ) async {
      await _pump(tester, await seededController(receipts: [_receipt]));

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.text('Pick a contact in WhatsApp'), findsOneWidget);
      expect(find.text('Opens your mail app'), findsOneWidget);
    });

    testWidgets('the details can be copied for anywhere else', (tester) async {
      // The catch-all for every platform with no deep link worth special
      // casing — Signal, Slack, a note, a printed sheet.
      await _pump(tester, await seededController(receipts: [_receipt]));

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.text('Copy the details'), findsOneWidget);
    });
  });
}
