import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

PurchaseOrderLine line(
  String itemId,
  String name, {
  int quantity = 10,
  double cost = 100,
  String id = 'l1',
}) => PurchaseOrderLine(
  id: id,
  itemId: itemId,
  itemName: name,
  quantityOrdered: quantity,
  unitCost: cost,
);

Future<(InventoryController, PurchaseOrder, String)> placedOrder({
  int onHand = 0,
  double existingCost = 0,
  int ordered = 10,
  double cost = 100,
}) async {
  final c = await newController();
  final item = c.createItem(
    draft(name: 'Bolt', quantity: onHand, unitCost: existingCost),
  );
  final order = c.createPurchaseOrder(
    lines: [line(item.id, 'Bolt', quantity: ordered, cost: cost)],
  );
  c.placePurchaseOrder(order.id);
  return (c, c.purchaseOrderById(order.id)!, item.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lifecycle', () {
    test('references are sequential and never reused', () async {
      final c = await newController();

      final first = c.createPurchaseOrder();
      final second = c.createPurchaseOrder();
      c.deletePurchaseOrder(second.id);
      final third = c.createPurchaseOrder();

      expect(first.reference, 'PO-0001');
      expect(second.reference, 'PO-0002');
      expect(
        third.reference,
        'PO-0003',
        reason: 'a deleted order must not hand its number back',
      );
    });

    test('a draft moves no stock when placed', () async {
      final (c, order, itemId) = await placedOrder(onHand: 5, ordered: 10);

      expect(c.byId(itemId)!.quantity, 5);
      expect(order.status, PurchaseStatus.ordered);
      expect(order.orderedAt, isNotNull);
    });

    test('an empty draft cannot be placed', () async {
      final c = await newController();
      final order = c.createPurchaseOrder();

      c.placePurchaseOrder(order.id);

      expect(c.purchaseOrderById(order.id)!.status, PurchaseStatus.draft);
    });

    test('a placed order can no longer be edited', () async {
      final (c, order, _) = await placedOrder();

      c.updatePurchaseOrder(order.id, notes: 'changed my mind');

      expect(c.purchaseOrderById(order.id)!.notes, isEmpty);
    });

    test('the expected date defaults from the supplier lead time', () async {
      final c = await newController();
      final supplier = c.createSupplier(
        Supplier(
          id: '',
          name: 'Nexa',
          leadTimeDays: 14,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final order = c.createPurchaseOrder(supplierId: supplier.id);

      expect(order.expectedAt, isNotNull);
      expect(
        order.expectedAt!.difference(DateTime.now()).inDays,
        closeTo(14, 1),
      );
      expect(order.supplierName, 'Nexa');
    });

    test('an order that has received stock cannot be deleted', () async {
      final (c, order, _) = await placedOrder();
      c.receivePurchaseOrder(order.id, {'l1': 10});

      c.deletePurchaseOrder(order.id);

      expect(c.purchaseOrderById(order.id), isNotNull);
    });
  });

  group('receiving', () {
    test('a full receipt raises stock and closes the order', () async {
      final (c, order, itemId) = await placedOrder(onHand: 5, ordered: 10);

      final moved = c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(moved, 1);
      expect(c.byId(itemId)!.quantity, 15);
      expect(c.purchaseOrderById(order.id)!.status, PurchaseStatus.received);
      expect(c.purchaseOrderById(order.id)!.closedAt, isNotNull);
    });

    test('a partial receipt leaves the balance outstanding', () async {
      final (c, order, itemId) = await placedOrder(ordered: 10);

      c.receivePurchaseOrder(order.id, {'l1': 4});

      final after = c.purchaseOrderById(order.id)!;
      expect(c.byId(itemId)!.quantity, 4);
      expect(after.status, PurchaseStatus.partial);
      expect(after.unitsOutstanding, 6);

      c.receivePurchaseOrder(order.id, {'l1': 6});
      expect(c.purchaseOrderById(order.id)!.status, PurchaseStatus.received);
      expect(c.byId(itemId)!.quantity, 10);
    });

    test('over-receiving is clamped to what is outstanding', () async {
      final (c, order, itemId) = await placedOrder(ordered: 10);

      c.receivePurchaseOrder(order.id, {'l1': 999});

      expect(c.byId(itemId)!.quantity, 10);
      expect(c.purchaseOrderById(order.id)!.unitsReceived, 10);
    });

    test('receiving writes a movement tagged with the order', () async {
      final (c, order, _) = await placedOrder(ordered: 10);

      c.receivePurchaseOrder(order.id, {'l1': 10});

      final movement = c.movements.first;
      expect(movement.kind, MovementKind.stockIn);
      expect(movement.delta, 10);
      expect(movement.documentId, order.id);
      expect(movement.note, contains(order.reference));
    });

    test('cost is rolled forward as a weighted average', () async {
      // 10 on hand at 100, receiving 10 at 200 averages to 150.
      final (c, order, itemId) = await placedOrder(
        onHand: 10,
        existingCost: 100,
        ordered: 10,
        cost: 200,
      );

      c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 150);
    });

    test('cost is taken as-is when there was no stock to average', () async {
      final (c, order, itemId) = await placedOrder(
        onHand: 0,
        existingCost: 0,
        cost: 250,
      );

      c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 250);
    });

    test('a zero cost line leaves the existing cost alone', () async {
      final (c, order, itemId) = await placedOrder(
        onHand: 10,
        existingCost: 100,
        cost: 0,
      );

      c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 100);
      expect(c.byId(itemId)!.quantity, 20);
    });

    test('a cancelled order refuses stock', () async {
      final (c, order, itemId) = await placedOrder();
      c.cancelPurchaseOrder(order.id);

      final moved = c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(moved, 0);
      expect(c.byId(itemId)!.quantity, 0);
    });
  });

  test('orders, lines and counters survive a reload', () async {
    final repo = newRepository();
    final c = await controllerOver(repo);
    final item = c.createItem(draft(name: 'Bolt', quantity: 0));
    final order = c.createPurchaseOrder(
      lines: [line(item.id, 'Bolt', quantity: 8, cost: 50)],
      notes: 'Urgent',
    );
    c.placePurchaseOrder(order.id);
    c.receivePurchaseOrder(order.id, {'l1': 3});
    await pumpWrites();

    final reloaded = await repo.load();
    final saved = reloaded.purchaseOrders.single;
    expect(saved.reference, 'PO-0001');
    expect(saved.notes, 'Urgent');
    expect(saved.status, PurchaseStatus.partial);
    expect(saved.lines.single.quantityOrdered, 8);
    expect(saved.lines.single.quantityReceived, 3);
    expect(reloaded.items.single.quantity, 3);
    expect(reloaded.sequences['PO'], 1);
  });
}
