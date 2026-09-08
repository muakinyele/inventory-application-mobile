import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/models/transfer.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';
import 'package:stockpile/ui/widgets/app_sidebar.dart';
import 'package:stockpile/ui/widgets/charts.dart';
import 'package:stockpile/ui/widgets/status_pill.dart';
import 'package:stockpile/ui/widgets/product_card.dart';
import 'package:stockpile/ui/widgets/stat_card.dart';

const _phone = Size(390, 844);
const _desktop = Size(1280, 900);

/// Tall enough that a whole scrolling page is laid out at once — a ListView
/// only builds what fits, so off-screen cards are otherwise never found.
const _tallDesktop = Size(1280, 2600);

Future<InventoryController> _seededController() => newController(seeded: true);

Future<InventoryController> _pumpApp(
  WidgetTester tester, {
  required Size size,
  String initialLocation = '/',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = await _seededController();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: StockpileApp(initialLocation: initialLocation),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('responsive shell', () {
    testWidgets('phone width uses the tab bar, not the sidebar', (
      tester,
    ) async {
      await _pumpApp(tester, size: _phone);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(AppSidebar), findsNothing);
    });

    testWidgets('desktop width uses the sidebar, not the tab bar', (
      tester,
    ) async {
      await _pumpApp(tester, size: _desktop);

      expect(find.byType(AppSidebar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('the sidebar exposes every destination', (tester) async {
      await _pumpApp(tester, size: _desktop);

      for (final item in navItems) {
        expect(
          find.text(item.label),
          findsWidgets,
          reason: '${item.label} should be reachable from the sidebar',
        );
      }
      expect(find.text(settingsItem.label), findsWidgets);
    });

    testWidgets('the phone tab bar badges the reorder count', (tester) async {
      final controller = await _pumpApp(tester, size: _phone);
      final expected = controller.items
          .where((i) => i.status != StockStatus.ok)
          .length;

      expect(
        expected,
        greaterThan(0),
        reason: 'the sample catalogue must flag something to badge',
      );
      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('$expected'), findsWidgets);
    });

    testWidgets('the badge sits on Alerts, not whichever branch is fourth', (
      tester,
    ) async {
      await _pumpApp(tester, size: _phone);

      // The regression this guards: the badge was pinned to a hardcoded
      // branch index, so inserting a destination ahead of Alerts in the
      // sidebar silently moved the count onto the wrong tab — or, as it
      // happened, onto a branch that is not on the tab bar at all, which
      // made it disappear entirely.
      expect(
        find.descendant(
          of: find.widgetWithText(NavigationDestination, 'Alerts'),
          matching: find.byType(Badge),
        ),
        findsOneWidget,
      );
    });

    testWidgets('nothing is badged when no item needs reordering', (
      tester,
    ) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      controller.createItem(draft(name: 'Bolt', quantity: 50, reorderLevel: 5));

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Badge), findsNothing);
    });

    testWidgets('destinations not on the phone tab bar live behind More', (
      tester,
    ) async {
      await _pumpApp(tester, size: _phone);

      // Categories is one of the overflow destinations.
      expect(find.text('Categories'), findsNothing);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('Reports'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  group('dashboard', () {
    testWidgets('shows the four headline stats', (tester) async {
      await _pumpApp(tester, size: _desktop);

      expect(find.text('Dashboard'), findsWidgets);
      expect(find.byType(StatCard), findsNWidgets(4));
      expect(find.text('Total Items'), findsOneWidget);
      expect(find.text('Low Stock'), findsOneWidget);
      expect(find.text('Out of Stock'), findsOneWidget);
      expect(find.text('Total Value'), findsOneWidget);
    });

    testWidgets('charts stock health and value by location', (tester) async {
      await _pumpApp(tester, size: _tallDesktop);

      expect(find.text('Stock health'), findsOneWidget);
      expect(find.text('Value by location'), findsOneWidget);
      expect(find.byType(CategoryDonutChart), findsOneWidget);
      expect(find.byType(CategoryBarChart), findsOneWidget);
      // Status is legended by name, never carried by colour alone.
      expect(find.text('In stock'), findsWidgets);
      expect(find.text('Low stock'), findsWidgets);
      expect(find.text('Out of stock'), findsWidgets);
    });

    testWidgets('the dashboard does not repeat the Reports breakdowns', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop);

      expect(find.text('Stock value by category'), findsNothing);
      expect(find.text('Share of stock value'), findsNothing);
    });

    testWidgets('surfaces recent transactions', (tester) async {
      await _pumpApp(tester, size: _desktop);

      expect(find.text('Recent Transactions'), findsOneWidget);
      expect(find.text('View all'), findsWidgets);
    });
  });

  group('items', () {
    testWidgets('renders the catalogue as product cards', (tester) async {
      final controller = await _pumpApp(
        tester,
        size: _desktop,
        initialLocation: '/items',
      );

      expect(find.byType(ProductCard), findsNWidgets(controller.items.length));
    });

    testWidgets('quick adjust changes that item and offers undo', (
      tester,
    ) async {
      final controller = await _pumpApp(
        tester,
        size: _desktop,
        initialLocation: '/items',
      );

      const target = '27" Monitor';
      int quantityOf() =>
          controller.items.firstWhere((i) => i.name == target).quantity;
      final before = quantityOf();

      // Scope to that item's own card; every card has a "+".
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ProductCard, target),
          matching: find.byIcon(Icons.add),
        ),
      );
      await tester.pumpAndSettle();

      expect(quantityOf(), before + 1);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('searching filters the grid down', (tester) async {
      await _pumpApp(tester, size: _desktop, initialLocation: '/items');

      await tester.enterText(find.byType(TextField).first, 'monitor');
      await tester.pumpAndSettle();

      expect(find.text('27" Monitor'), findsOneWidget);
      expect(find.text('A4 Paper Ream'), findsNothing);
    });

    testWidgets('a status query parameter pre-filters the list', (
      tester,
    ) async {
      final controller = await _pumpApp(
        tester,
        size: _desktop,
        initialLocation: '/items?status=out',
      );

      final outOfStock = controller.items.where((i) => i.quantity <= 0).length;
      expect(find.byType(ProductCard), findsNWidgets(outOfStock));
    });

    testWidgets('a category query parameter pre-filters the list', (
      tester,
    ) async {
      final controller = await _pumpApp(
        tester,
        size: _desktop,
        initialLocation: '/items?category=Packaging',
      );

      final packaging = controller.items
          .where((i) => i.category == 'Packaging')
          .length;
      expect(find.byType(ProductCard), findsNWidgets(packaging));
    });

    testWidgets('an item URL deep-links to its detail screen', (tester) async {
      await _pumpApp(tester, size: _desktop, initialLocation: '/items/seed-1');

      expect(find.text('USB-C Cable 2m'), findsWidgets);
      expect(find.text('Stock in'), findsOneWidget);
      expect(find.text('Stock out'), findsOneWidget);
    });
  });

  group('purchase orders', () {
    testWidgets('the page offers a way to raise one when empty', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        size: _tallDesktop,
        initialLocation: '/purchase-orders',
      );

      expect(find.text('Purchase Orders'), findsWidgets);
      expect(find.text('No purchase orders yet'), findsOneWidget);
      expect(find.text('New Order'), findsWidgets);
    });

    testWidgets('an order shows its reference, status and progress', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController(seeded: true);
      final item = controller.items.first;
      final order = controller.createPurchaseOrder(
        lines: [
          PurchaseOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: item.name,
            quantityOrdered: 10,
            unitCost: 500,
          ),
        ],
      );
      controller.placePurchaseOrder(order.id);
      controller.receivePurchaseOrder(order.id, {'l1': 4});

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/purchase-orders'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PO-0001'), findsOneWidget);
      expect(find.byType(PurchaseStatusPill), findsWidgets);
      expect(find.text('Part received'), findsWidgets);
      expect(find.text('4 of 10 received'), findsOneWidget);
    });
  });

  group('sales orders', () {
    testWidgets('the page offers a way to raise one when empty', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        size: _tallDesktop,
        initialLocation: '/sales-orders',
      );

      expect(find.text('Sales Orders'), findsWidgets);
      expect(find.text('No sales yet'), findsOneWidget);
      expect(find.text('New Sale'), findsWidgets);
    });

    testWidgets('a sale shows its reference, status and progress', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController(seeded: true);
      final item = controller.items.firstWhere((i) => i.quantity >= 10);
      final order = controller.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: item.name,
            quantityOrdered: 10,
            unitPrice: 900,
          ),
        ],
      );
      controller.confirmSalesOrder(order.id);
      controller.fulfilSalesOrder(order.id, {'l1': 4});

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/sales-orders'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SO-0001'), findsOneWidget);
      expect(find.byType(SalesStatusPill), findsWidgets);
      expect(find.text('Part sent'), findsWidgets);
      expect(find.text('4 of 10 sent'), findsOneWidget);
    });

    testWidgets('a shipped sale reports its margin', (tester) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 20, unitCost: 100),
      );
      final order = controller.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 10,
            unitPrice: 500,
          ),
        ],
      );
      controller.confirmSalesOrder(order.id);
      controller.fulfilSalesOrder(order.id, {'l1': 10});

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/sales-orders/${order.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Margin on what has shipped'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
    });
  });

  group('receipts', () {
    testWidgets('the page offers a way to raise one when empty', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/receipts');

      expect(find.text('Receipts'), findsWidgets);
      expect(find.text('No receipts yet'), findsOneWidget);
      expect(find.text('New Receipt'), findsWidgets);
    });

    testWidgets('a receipt lists its reference, payment and total', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 20, unitCost: 100),
      );
      controller.issueReceipt(
        method: PaymentMethod.card,
        lines: [
          ReceiptLine(
            id: 'rl1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 3,
            unitPrice: 500,
          ),
        ],
        amountPaid: 1500,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/receipts'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('RC-0001'), findsOneWidget);
      expect(find.byType(ReceiptStatusPill), findsWidgets);
      expect(find.textContaining('Card'), findsWidgets);
    });

    testWidgets('a receipt deep-links to its own page and totals', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 20, unitCost: 100),
      );
      final receipt = controller.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'rl1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 3,
            unitPrice: 500,
          ),
        ],
        amountPaid: 2000,
      )!;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/receipts/${receipt.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('RC-0001'), findsWidgets);
      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Total'), findsWidgets);
      expect(find.text('Change given'), findsOneWidget);
      // Margin on 3 units at 500 sold against a cost of 100.
      expect(find.text('Gross profit'), findsOneWidget);
    });

    testWidgets('a voided receipt says so and offers no refund', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(draft(name: 'Bolt', quantity: 20));
      final receipt = controller.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'rl1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 3,
            unitPrice: 500,
          ),
        ],
      )!;
      controller.voidReceipt(receipt.id, reason: 'Rang up twice');

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/receipts/${receipt.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('This receipt has been voided'), findsOneWidget);
      expect(find.text('Rang up twice'), findsOneWidget);
      expect(find.text('Refund'), findsNothing);
      expect(find.text('Void'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('a sale that has sent stock offers a receipt', (tester) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(draft(name: 'Bolt', quantity: 20));
      final order = controller.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 10,
            unitPrice: 900,
          ),
        ],
      );
      controller.confirmSalesOrder(order.id);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/sales-orders/${order.id}'),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing has gone out, so there is nothing to receipt yet.
      expect(find.text('Issue receipt'), findsNothing);

      controller.fulfilSalesOrder(order.id, {'l1': 4});
      await tester.pumpAndSettle();

      expect(find.text('Issue receipt'), findsOneWidget);
    });

    testWidgets('the editor prices a counter sale as items are picked', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      controller.createItem(
        draft(name: 'Bolt', quantity: 20, retailerPrice: 750),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/receipts/new'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Item').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Bolt').last);
      await tester.pumpAndSettle();

      // One unit at the retailer price, with the tendered amount kept in step.
      expect(find.textContaining('Issue receipt'), findsOneWidget);
      expect(find.text('750.00'), findsOneWidget);
    });
  });

  group('invoices and trading reports', () {
    testWidgets('the invoices page offers a way to raise one when empty', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/invoices');

      expect(find.text('Invoices'), findsWidgets);
      expect(find.text('No invoices yet'), findsOneWidget);
      expect(find.text('New Invoice'), findsWidgets);
    });

    testWidgets('an invoice shows what is owed and by when', (tester) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 50, unitCost: 100),
      );
      final invoice = controller.issueInvoice(
        lines: [
          InvoiceLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 4,
            unitPrice: 500,
          ),
        ],
        termDays: 30,
      )!;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/invoices/${invoice.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('INV-0001'), findsWidgets);
      expect(find.byType(InvoiceStatusPill), findsWidgets);
      expect(find.text('Balance due'), findsOneWidget);
      expect(find.text('Record payment'), findsOneWidget);
      expect(find.text('Download PDF'), findsOneWidget);
      // Nothing paid yet, so nothing to list.
      expect(find.text('Receipts issued'), findsNothing);
      expect(invoice.balanceDue, 2000);
    });

    testWidgets('paying an invoice lists the receipt it issued', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 50, unitCost: 100),
      );
      final invoice = controller.issueInvoice(
        lines: [
          InvoiceLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 4,
            unitPrice: 500,
          ),
        ],
      )!;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/invoices/${invoice.id}'),
        ),
      );
      await tester.pumpAndSettle();

      controller.payInvoice(invoice.id, 800, method: PaymentMethod.transfer);
      await tester.pumpAndSettle();

      expect(find.text('Receipts issued'), findsOneWidget);
      expect(find.text('RC-0001'), findsWidgets);
      expect(find.text('Part paid'), findsWidgets);
    });

    testWidgets('the report shows revenue, cost, profit and margin', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 50, unitCost: 100),
      );
      controller.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/reports'),
        ),
      );
      await tester.pumpAndSettle();

      // The four figures the whole report exists for.
      expect(find.text('Revenue'), findsWidgets);
      expect(find.text('Cost of Goods'), findsWidgets);
      expect(find.text('Gross Profit'), findsWidgets);
      expect(find.text('Profit Margin'), findsWidgets);
      // And the per-item table under them.
      expect(find.text('Profit by item'), findsOneWidget);
      expect(find.text('Total'), findsWidgets);
      expect(find.text('80.0%'), findsWidgets);
    });

    testWidgets('every reporting period is offered', (tester) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/reports');

      for (final label in ['Daily', 'Weekly', 'Monthly', 'Yearly', 'Custom']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('PDF'), findsOneWidget);
      expect(find.text('Excel'), findsOneWidget);
    });

    testWidgets('a period with no sales says so rather than showing zeroes '
        'as facts', (tester) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/reports');

      // The seeded catalogue has stock but no sales.
      expect(find.text('Nothing sold in this period'), findsOneWidget);
      expect(find.text('Stock on hand'), findsOneWidget);
    });
  });

  group('transfers', () {
    testWidgets('the page offers a way to move stock when empty', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/transfers');

      expect(find.text('Transfers'), findsWidgets);
      expect(find.text('Nothing moved yet'), findsOneWidget);
      expect(find.text('Move Stock'), findsWidgets);
    });

    testWidgets('a transfer shows its route and what moved', (tester) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );
      controller.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Store Front',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 4,
          ),
        ],
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/transfers'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TR-0001'), findsOneWidget);
      expect(find.text('Warehouse'), findsWidgets);
      expect(find.text('Store Front'), findsWidgets);
      expect(find.text('4 units'), findsOneWidget);

      // The breakdown must account for every unit, not a top few, or it
      // reads as if the numbers shown are the whole picture.
      expect(find.text('Where your stock is'), findsOneWidget);
      expect(find.text('10 units'), findsOneWidget);
      expect(find.text('6  ·  60%'), findsOneWidget);
      expect(find.text('4  ·  40%'), findsOneWidget);
    });

    testWidgets('an item split across bins shows where it is', (tester) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );
      controller.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Van',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 4,
          ),
        ],
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/items/${item.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Where it is'), findsOneWidget);
      expect(find.text('6 pcs'), findsOneWidget);
      expect(find.text('4 pcs'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('an item in one place does not need the breakdown', (
      tester,
    ) async {
      tester.view.physicalSize = _tallDesktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController();
      final item = controller.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: StockpileApp(initialLocation: '/items/${item.id}'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Where it is'), findsNothing);
    });
  });

  group('new pages', () {
    testWidgets('categories lists each category with its item count', (
      tester,
    ) async {
      await _pumpApp(tester, size: _desktop, initialLocation: '/categories');

      expect(find.text('Categories'), findsWidgets);
      expect(find.text('Add Category'), findsWidgets);
      expect(find.text('Packaging'), findsOneWidget);
      // Two seeded items are packaging.
      expect(find.text('2 items'), findsWidgets);
    });

    testWidgets('reports charts stock by value, share and movement', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/reports');

      expect(find.text('Reports'), findsWidgets);
      expect(find.text('Inventory Value'), findsOneWidget);
      expect(find.text('Stock value by category'), findsOneWidget);
      expect(find.text('Share of stock value'), findsOneWidget);
      expect(find.text('Stock movement — last 14 days'), findsOneWidget);
      expect(find.text('Units held by category'), findsOneWidget);
      expect(find.text('Top items by stock value'), findsOneWidget);

      // The charts themselves render, not just their cards.
      expect(find.byType(CategoryBarChart), findsOneWidget);
      expect(find.byType(CategoryDonutChart), findsNWidgets(2));
      expect(find.byType(FlowChart), findsOneWidget);
    });

    testWidgets('the donut never shows more slices than it can be read at', (
      tester,
    ) async {
      await _pumpApp(tester, size: _tallDesktop, initialLocation: '/reports');

      final donut = tester.widget<CategoryDonutChart>(
        find.byType(CategoryDonutChart).first,
      );
      expect(donut.slices.length, lessThanOrEqualTo(6));
      // Every slice is legended by name, so colour is never the only channel.
      for (final slice in donut.slices) {
        expect(find.text(slice.label), findsWidgets);
      }
    });

    testWidgets('reports stacks its charts on a phone rather than clipping', (
      tester,
    ) async {
      // Tall so the whole page lays out; narrow so the two-up rows collapse.
      // The height has to clear both report sections — trading and stock —
      // or a ListView simply never builds the charts further down.
      await _pumpApp(
        tester,
        size: const Size(390, 5000),
        initialLocation: '/reports',
      );

      expect(find.byType(CategoryBarChart), findsOneWidget);
      expect(find.byType(CategoryDonutChart), findsNWidgets(2));
      expect(find.byType(FlowChart), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('alerts lists the items needing a reorder', (tester) async {
      final controller = await _pumpApp(
        tester,
        size: _desktop,
        initialLocation: '/alerts',
      );

      expect(find.text('Alerts'), findsWidgets);
      expect(controller.needsAttention, isNotEmpty);
      expect(find.text('Shipping Box (M)'), findsOneWidget);
    });

    testWidgets('alerts shows the all-clear when nothing is flagged', (
      tester,
    ) async {
      tester.view.physicalSize = _desktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await _seededController();
      controller.eraseAll();
      final now = DateTime.now();
      controller.createItem(
        Item(
          id: '',
          name: 'Well stocked',
          quantity: 500,
          reorderLevel: 10,
          createdAt: now,
          updatedAt: now,
        ),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/alerts'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('All stocked up!'), findsOneWidget);
    });
  });
}
