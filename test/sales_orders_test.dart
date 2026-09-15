import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/movement.dart';
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
  final item = c.createItem(
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
    test('references are sequential and never reused', () async {
      final c = await newController();

      final first = await c.createSalesOrder();
      final second = await c.createSalesOrder();
      c.deleteSalesOrder(second.id);
      final third = await c.createSalesOrder();

      expect(first.reference, 'SO-0001');
      expect(second.reference, 'SO-0002');
      expect(
        third.reference,
        'SO-0003',
        reason: 'a deleted sale must not hand its number back',
      );
    });

    test('sales and purchases count on separate sequences', () async {
      final c = await newController();

      expect((await c.createPurchaseOrder()).reference, 'PO-0001');
      expect((await c.createSalesOrder()).reference, 'SO-0001');
      expect((await c.createSalesOrder()).reference, 'SO-0002');
      expect((await c.createPurchaseOrder()).reference, 'PO-0002');
    });

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

    test('a sale that has shipped cannot be deleted', () async {
      final (c, order, _) = await confirmedSale(ordered: 4);
      await c.fulfilSalesOrder(order.id, {'l1': 4});

      c.deleteSalesOrder(order.id);

      expect(c.salesOrderById(order.id), isNotNull);
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
        final buyer = c.createCustomer(customer(tier: PriceTier.distributor));

        final order = await c.createSalesOrder(customerId: buyer.id);

        expect(order.priceTier, PriceTier.distributor);
        expect(order.customerName, 'Bello Stores');

        // Re-tiering the customer must not rewrite a sale already raised.
        c.updateCustomer(
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
    test('a full send empties the line and closes the sale', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 20, ordered: 10);

      final moved = await c.fulfilSalesOrder(order.id, {'l1': 10});

      expect(moved, 1);
      expect(c.byId(itemId)!.quantity, 10);
      final after = c.salesOrderById(order.id)!;
      expect(after.status, SalesStatus.fulfilled);
      expect(after.unitsOutstanding, 0);
      expect(after.closedAt, isNotNull);
    });

    test('a part send leaves the balance outstanding', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 20, ordered: 10);

      await c.fulfilSalesOrder(order.id, {'l1': 4});

      expect(c.byId(itemId)!.quantity, 16);
      final after = c.salesOrderById(order.id)!;
      expect(after.status, SalesStatus.partial);
      expect(after.unitsFulfilled, 4);
      expect(after.unitsOutstanding, 6);
    });

    test('sending more than ordered is clamped to the balance', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 50, ordered: 10);

      await c.fulfilSalesOrder(order.id, {'l1': 99});

      expect(c.byId(itemId)!.quantity, 40);
      expect(c.salesOrderById(order.id)!.unitsFulfilled, 10);
    });

    test('stock is never sent below zero', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 3, ordered: 10);

      await c.fulfilSalesOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.quantity, 0);
      final after = c.salesOrderById(order.id)!;
      expect(after.unitsFulfilled, 3);
      expect(
        after.status,
        SalesStatus.partial,
        reason: 'the balance the shelf could not cover stays outstanding',
      );
    });

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

    test('each send raises a movement tagged with the sale', () async {
      final (c, order, itemId) = await confirmedSale(onHand: 20, ordered: 10);

      await c.fulfilSalesOrder(order.id, {'l1': 6});

      final movement = c.movements.first;
      expect(movement.documentId, order.id);
      expect(movement.itemId, itemId);
      expect(movement.kind, MovementKind.stockOut);
      expect(movement.before, 20);
      expect(movement.after, 14);
      expect(movement.note, 'Sold on ${order.reference}');
    });
  });

  group('margin', () {
    test('cost of goods is banked at the cost on the day it shipped', () async {
      final (c, order, itemId) = await confirmedSale(
        onHand: 20,
        unitCost: 100,
        ordered: 10,
        price: 500,
      );

      await c.fulfilSalesOrder(order.id, {'l1': 5});

      // A later restock at a higher price moves the average cost, which must
      // not rewrite what the first five units actually cost.
      final po = await c.createPurchaseOrder(
        lines: [purchaseLine(itemId, 'Bolt', quantity: 15, cost: 300)],
      );
      c.placePurchaseOrder(po.id);
      await c.receivePurchaseOrder(po.id, {'pl1': 15});
      await c.fulfilSalesOrder(order.id, {'l1': 5});

      final after = c.salesOrderById(order.id)!;
      // 5 @ 100, then 5 @ the rolled-forward average of
      // (15 * 100 + 15 * 300) / 30 = 200. So 500 + 1000 = 1500.
      expect(after.costOfGoods, closeTo(1500, 0.01));
      expect(after.revenue, 5000);
      expect(after.grossProfit, closeTo(3500, 0.01));
      expect(after.marginRate, closeTo(0.7, 0.001));
    });

    test('margin is null until something ships', () async {
      final (c, order, _) = await confirmedSale();

      expect(c.salesOrderById(order.id)!.marginRate, isNull);
      expect(c.salesOrderById(order.id)!.grossProfit, 0);
    });

    test('revenue counts what shipped, total counts what was quoted', () async {
      final (c, order, _) = await confirmedSale(ordered: 10, price: 500);

      await c.fulfilSalesOrder(order.id, {'l1': 3});

      final after = c.salesOrderById(order.id)!;
      expect(after.total, 5000);
      expect(after.revenue, 1500);
    });
  });

  group('persistence', () {
    test('a sale survives a full reload, counter included', () async {
      final repo = newRepository();
      final first = await controllerOver(repo);
      final item = first.createItem(draft(name: 'Bolt', quantity: 20));
      final order = await first.createSalesOrder(
        notes: 'Deliver to the back gate',
        lines: [line(item.id, 'Bolt', quantity: 8, price: 750)],
      );
      first.confirmSalesOrder(order.id);
      await first.fulfilSalesOrder(order.id, {'l1': 3});
      await pumpWrites();

      final second = await controllerOver(repo);
      final reloaded = second.salesOrderById(order.id)!;

      expect(reloaded.reference, 'SO-0001');
      expect(reloaded.status, SalesStatus.partial);
      expect(reloaded.notes, 'Deliver to the back gate');
      expect(reloaded.lines.single.quantityOrdered, 8);
      expect(reloaded.lines.single.quantityFulfilled, 3);
      expect(reloaded.lines.single.unitPrice, 750);
      expect(reloaded.lines.single.costOfGoods, closeTo(6, 0.01));
      expect(second.byId(item.id)!.quantity, 17);
      expect(
        (await second.createSalesOrder()).reference,
        'SO-0002',
        reason: 'the counter must carry across a reload',
      );
    });
  });
}
