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
  final item = await c.createItem(
    draft(name: 'Bolt', quantity: onHand, unitCost: existingCost),
  );
  final order = await c.createPurchaseOrder(
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

      final first = await c.createPurchaseOrder();
      final second = await c.createPurchaseOrder();
      c.deletePurchaseOrder(second.id);
      final third = await c.createPurchaseOrder();

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
      final order = await c.createPurchaseOrder();

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
      final supplier = await c.createSupplier(
        Supplier(
          id: '',
          name: 'Nexa',
          leadTimeDays: 14,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final order = await c.createPurchaseOrder(supplierId: supplier.id);

      expect(order.expectedAt, isNotNull);
      expect(
        order.expectedAt!.difference(DateTime.now()).inDays,
        closeTo(14, 1),
      );
      expect(order.supplierName, 'Nexa');
    });

    test('an order that has received stock cannot be deleted', () async {
      final (c, order, _) = await placedOrder();
      await c.receivePurchaseOrder(order.id, {'l1': 10});

      c.deletePurchaseOrder(order.id);

      expect(c.purchaseOrderById(order.id), isNotNull);
    });
  });

  group('receiving', () {
    test('a full receipt raises stock and closes the order', () async {
      final (c, order, itemId) = await placedOrder(onHand: 5, ordered: 10);

      final moved = await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(moved, 1);
      expect(c.byId(itemId)!.quantity, 15);
      expect(c.purchaseOrderById(order.id)!.status, PurchaseStatus.received);
      expect(c.purchaseOrderById(order.id)!.closedAt, isNotNull);
    });

    test('a partial receipt leaves the balance outstanding', () async {
      final (c, order, itemId) = await placedOrder(ordered: 10);

      await c.receivePurchaseOrder(order.id, {'l1': 4});

      final after = c.purchaseOrderById(order.id)!;
      expect(c.byId(itemId)!.quantity, 4);
      expect(after.status, PurchaseStatus.partial);
      expect(after.unitsOutstanding, 6);

      await c.receivePurchaseOrder(order.id, {'l1': 6});
      expect(c.purchaseOrderById(order.id)!.status, PurchaseStatus.received);
      expect(c.byId(itemId)!.quantity, 10);
    });

    test('over-receiving is clamped to what is outstanding', () async {
      final (c, order, itemId) = await placedOrder(ordered: 10);

      await c.receivePurchaseOrder(order.id, {'l1': 999});

      expect(c.byId(itemId)!.quantity, 10);
      expect(c.purchaseOrderById(order.id)!.unitsReceived, 10);
    });

    test('receiving writes a movement tagged with the order', () async {
      final (c, order, _) = await placedOrder(ordered: 10);

      await c.receivePurchaseOrder(order.id, {'l1': 10});

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

      await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 150);
    });

    test('cost is taken as-is when there was no stock to average', () async {
      final (c, order, itemId) = await placedOrder(
        onHand: 0,
        existingCost: 0,
        cost: 250,
      );

      await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 250);
    });

    test('a zero cost line leaves the existing cost alone', () async {
      final (c, order, itemId) = await placedOrder(
        onHand: 10,
        existingCost: 100,
        cost: 0,
      );

      await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(c.byId(itemId)!.unitCost, 100);
      expect(c.byId(itemId)!.quantity, 20);
    });

    test('a cancelled order refuses stock', () async {
      final (c, order, itemId) = await placedOrder();
      c.cancelPurchaseOrder(order.id);

      final moved = await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(moved, 0);
      expect(c.byId(itemId)!.quantity, 0);
    });
  });
}
