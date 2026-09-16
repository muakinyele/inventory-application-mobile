import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

SalesOrderLine line(
  String itemId,
  String name, {
  int quantity = 10,
  double price = 500,
  String id = 'l1',
}) => SalesOrderLine(
  id: id,
  itemId: itemId,
  itemName: name,
  quantityOrdered: quantity,
  unitPrice: price,
);

PurchaseOrderLine purchaseLine(
  String itemId,
  String name, {
  int quantity = 10,
  double cost = 100,
  String id = 'pl1',
}) => PurchaseOrderLine(
  id: id,
  itemId: itemId,
  itemName: name,
  quantityOrdered: quantity,
  unitCost: cost,
);

Customer customer({
  String name = 'Bello Stores',
  PriceTier tier = PriceTier.distributor,
}) {
  final now = DateTime.now();
  return Customer(
    id: '',
    name: name,
    priceTier: tier,
    createdAt: now,
    updatedAt: now,
  );
}

Future<(InventoryController, SalesOrder, String)> confirmedSale({
  int onHand = 20,
  double unitCost = 100,
  int ordered = 10,
  double price = 500,
}) async {
  final c = await newController();
  final item = await c.createItem(
    draft(name: 'Bolt', quantity: onHand, unitCost: unitCost),
  );
  final order = await c.createSalesOrder(
    lines: [line(item.id, 'Bolt', quantity: ordered, price: price)],
  );
  c.confirmSalesOrder(order.id);
  return (c, c.salesOrderById(order.id)!, item.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lifecycle', () {
    test('confirming a sale moves no stock', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 20);

      expect(order.status, SalesStatus.confirmed);
      expect(c.byId(itemId)!.quantity, 20);
      expect(c.movements.where((m) => m.documentId == order.id), isEmpty);
    });

    test('an empty draft refuses to confirm', () async {
      final c = await newController();
      final order = await c.createSalesOrder();

      c.confirmSalesOrder(order.id);

      expect(c.salesOrderById(order.id)!.status, SalesStatus.draft);
    });

    test('a confirmed sale refuses edits', () async {
      final (c, order, itemId) = await confirmedSale();

      c.updateSalesOrder(order.id, notes: 'changed my mind');

      expect(c.salesOrderById(order.id)!.notes, '');
      expect(itemId, isNotEmpty);
    });

    test('a cancelled sale sends nothing', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 20, ordered: 5);
      c.cancelSalesOrder(order.id);

      final moved = await c.fulfilSalesOrder(order.id, {'l1': 5});

      expect(moved, 0);
      expect(c.byId(itemId)!.quantity, 20);
    });
  });

  group('pricing', () {
    test(
      'the tier is taken from the customer and frozen on the sale',
      () async {
        final c = await newController();
        final buyer = await c.createCustomer(
          customer(tier: PriceTier.distributor),
        );

        final order = await c.createSalesOrder(customerId: buyer.id);

        expect(order.priceTier, PriceTier.distributor);
        expect(order.customerName, 'Bello Stores');

        // Re-tiering the customer must not rewrite a sale already raised.
        await c.updateCustomer(
          buyer.id,
          c.customerById(buyer.id)!.copyWith(priceTier: PriceTier.retailer),
        );

        expect(c.salesOrderById(order.id)!.priceTier, PriceTier.distributor);
      },
    );

    test('a walk-in is quoted at retailer rates', () async {
      final c = await newController();

      expect((await c.createSalesOrder()).priceTier, PriceTier.retailer);
      expect(c.priceTierFor(null), PriceTier.retailer);
    });

    test('an item quotes the price for the tier', () {
      final now = DateTime.now();
      final item = Item(
        id: 'i',
        name: 'Bolt',
        retailerPrice: 1200,
        distributorPrice: 900,
        createdAt: now,
        updatedAt: now,
      );

      expect(item.priceFor(PriceTier.retailer), 1200);
      expect(item.priceFor(PriceTier.distributor), 900);
    });

    test('a missing tier price falls back to the other one', () {
      final now = DateTime.now();
      final retailOnly = Item(
        id: 'i',
        name: 'Bolt',
        retailerPrice: 1200,
        createdAt: now,
        updatedAt: now,
      );

      expect(
        retailOnly.priceFor(PriceTier.distributor),
        1200,
        reason:
            'a sale must never be quoted at zero just because only one '
            'price was filled in',
      );
    });
  });

  group('sending stock', () {
    test('sendableOn reports what the shelf can actually cover', () async {
      final (c, order, _) = await confirmedSale(onHand: 3, ordered: 10);

      expect(c.sendableOn(order, order.lines.first), 3);
    });

    test('a send with nothing on the shelf moves nothing', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 0, ordered: 10);

      final moved = await c.fulfilSalesOrder(order.id, {'l1': 10});

      expect(moved, 0);
      expect(c.byId(itemId)!.quantity, 0);
      expect(c.salesOrderById(order.id)!.status, SalesStatus.confirmed);
    });
  });

  group('margin', () {
    test('margin is null until something ships', () async {
      final (c, order, _) = await confirmedSale();

      expect(c.salesOrderById(order.id)!.marginRate, isNull);
      expect(c.salesOrderById(order.id)!.grossProfit, 0);
    });
  });

  group('persistence', () {});
}
