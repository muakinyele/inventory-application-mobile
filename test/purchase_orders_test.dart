import 'package:flutter_test/flutter_test.dart';
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
  });

  group('receiving', () {
    test('a cancelled order refuses stock', () async {
      final (c, order, itemId) = await placedOrder();
      c.cancelPurchaseOrder(order.id);

      final moved = await c.receivePurchaseOrder(order.id, {'l1': 10});

      expect(moved, 0);
      expect(c.byId(itemId)!.quantity, 0);
    });
  });
}
