import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

const _desktop = Size(1400, 2600);

Customer _customer({String id = 'c1', String name = 'Ada Nwosu'}) {
  final now = DateTime.utc(2026, 9, 1);
  return Customer(
    id: id,
    name: name,
    contactName: '',
    phone: '',
    email: '',
    address: '',
    priceTier: PriceTier.retailer,
    notes: '',
    createdAt: now,
    updatedAt: now,
  );
}

SalesOrder _sale({String? customerId, String customerName = ''}) => SalesOrder(
  id: 'so1',
  reference: 'SO-0021',
  customerId: customerId,
  customerName: customerName,
  status: SalesStatus.confirmed,
  confirmedAt: DateTime.utc(2026, 9, 22),
  lines: const [
    SalesOrderLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantityOrdered: 2,
      quantityFulfilled: 2,
      unitPrice: 500,
    ),
  ],
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
);

Future<void> _pump(WidgetTester tester, InventoryController controller) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: const StockpileApp(initialLocation: '/invoices/new?sale=so1'),
    ),
  );
  await tester.pumpAndSettle();
}

/// The dropdown, so its state can be asserted on rather than inferred.
DropdownButtonFormField<String?> _billTo(WidgetTester tester) =>
    tester.widget<DropdownButtonFormField<String?>>(
      find.byType(DropdownButtonFormField<String?>).first,
    );

void main() {
  group('billing an invoice raised from a sale', () {
    testWidgets('the sale\'s customer is shown and cannot be changed', (
      tester,
    ) async {
      final controller = await seededController(
        customers: [_customer()],
        salesOrders: [_sale(customerId: 'c1', customerName: 'Ada Nwosu')],
      );

      await _pump(tester, controller);

      expect(find.text('Taken from the sale'), findsOneWidget);
      expect(
        _billTo(tester).onChanged,
        isNull,
        reason: 'the sale settled who is billed',
      );
    });

    // THE BUG. A sale can be raised without a customer — a walk-in later put
    // on account — and invoicing one left this field disabled AND empty: no
    // customer, no way to choose one, and a credit invoice with nobody to
    // bill.
    testWidgets('a sale with no customer lets you choose one', (tester) async {
      final controller = await seededController(
        customers: [
          _customer(),
          _customer(id: 'c2', name: 'Bola Ade'),
        ],
        salesOrders: [_sale()],
      );

      await _pump(tester, controller);

      expect(
        _billTo(tester).onChanged,
        isNotNull,
        reason: 'there is nobody to bill until this is answered',
      );
      expect(
        find.text('That sale had no customer — choose who to bill'),
        findsOneWidget,
      );
    });

    testWidgets('and the whole customer list is offered', (tester) async {
      final controller = await seededController(
        customers: [
          _customer(),
          _customer(id: 'c2', name: 'Bola Ade'),
        ],
        salesOrders: [_sale()],
      );
      await _pump(tester, controller);

      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
      await tester.pumpAndSettle();

      expect(find.textContaining('Ada Nwosu'), findsWidgets);
      expect(find.textContaining('Bola Ade'), findsWidgets);
    });

    // A selected value with no matching item renders blank and asserts in
    // debug, so an archived customer made the field show nobody at all for a
    // sale that plainly had one.
    testWidgets('a customer archived since the sale still shows', (
      tester,
    ) async {
      final controller = await seededController(
        customers: const [], // archived, so no longer in the picker
        salesOrders: [_sale(customerId: 'gone', customerName: 'Ada Nwosu')],
      );

      await _pump(tester, controller);

      expect(find.textContaining('no longer listed'), findsWidgets);
      expect(
        tester.takeException(),
        isNull,
        reason: 'a value with no item is what throws',
      );
    });

    testWidgets('an unnamed archived customer still gets a label', (
      tester,
    ) async {
      final controller = await seededController(
        customers: const [],
        salesOrders: [_sale(customerId: 'gone')],
      );

      await _pump(tester, controller);

      expect(find.textContaining("This sale's customer"), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
