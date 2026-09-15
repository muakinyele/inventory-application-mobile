import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/models/transfer.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

/// The rule the whole feature rests on: an item's bins always add up to the
/// number the rest of the app reads.
void expectBalanced(InventoryController c, {String? because}) {
  for (final item in c.items) {
    final bins = c.stockByLocation(item.id);
    final summed = bins.values.fold(0, (sum, q) => sum + q);
    expect(
      summed,
      item.quantity,
      reason:
          '${item.name}: bins $bins sum to $summed but quantity is '
          '${item.quantity}${because == null ? '' : ' — $because'}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the breakdown follows the total', () {
    test('a new item puts all its stock in its own location', () async {
      final c = await newController();

      final item = c.createItem(
        draft(name: 'Bolt', quantity: 12).copyWith(location: 'Warehouse'),
      );

      expect(c.stockByLocation(item.id), {'Warehouse': 12});
      expectBalanced(c);
    });

    test('stock with no location lands in Unassigned', () async {
      final c = await newController();

      final item = c.createItem(draft(name: 'Bolt', quantity: 5));

      expect(c.stockByLocation(item.id), {unassignedLocation: 5});
      expectBalanced(c);
    });

    test('an adjustment books into the home bin', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      c.adjustStock(item.id, 5);

      expect(c.stockByLocation(item.id), {'Warehouse': 15});
      expectBalanced(c);
    });

    test('a receipt books into the home bin', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 4).copyWith(location: 'Warehouse'),
      );
      final po = await c.createPurchaseOrder(
        lines: [
          PurchaseOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 6,
            unitCost: 10,
          ),
        ],
      );
      c.placePurchaseOrder(po.id);
      await c.receivePurchaseOrder(po.id, {'l1': 6});

      expect(c.stockByLocation(item.id), {'Warehouse': 10});
      expectBalanced(c);
    });

    test('deleting an item drops its bins', () async {
      final c = await newController();
      final item = c.createItem(draft(name: 'Bolt', quantity: 10));

      c.deleteItem(item.id);

      expect(c.stockByLocation(item.id), isEmpty);
      expect(c.unitsByLocation, isEmpty);
    });

    test('editing the location moves the stock with it', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      c.updateItem(item.id, c.byId(item.id)!.copyWith(location: 'Store Front'));

      expect(c.stockByLocation(item.id), {'Store Front': 10});
      expectBalanced(c);
    });

    test(
      'stock parked elsewhere stays put when the home bin is renamed',
      () async {
        final c = await newController();
        final item = c.createItem(
          draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
        );
        c.recordTransfer(
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

        c.updateItem(
          item.id,
          c.byId(item.id)!.copyWith(location: 'Store Front'),
        );

        expect(c.stockByLocation(item.id), {'Store Front': 6, 'Van': 4});
        expectBalanced(c, because: 'only the home bin should relocate');
      },
    );
  });

  group('draining', () {
    test('a sale empties the home bin before touching the others', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );
      c.recordTransfer(
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

      final so = c.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 8,
            unitPrice: 100,
          ),
        ],
      );
      c.confirmSalesOrder(so.id);
      c.fulfilSalesOrder(so.id, {'l1': 8});

      // 6 in Warehouse goes first, then the remaining 2 come out of the Van.
      expect(c.stockByLocation(item.id), {'Van': 2});
      expectBalanced(c);
    });

    test('emptying an item leaves no bins behind', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 6).copyWith(location: 'Warehouse'),
      );

      c.adjustStock(item.id, -6);

      expect(c.stockByLocation(item.id), isEmpty);
      expectBalanced(c);
    });
  });

  group('transfers', () {
    test('a transfer moves stock without changing the total', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      final transfer = c.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Store Front',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 3,
          ),
        ],
      )!;

      expect(transfer.reference, 'TR-0001');
      expect(transfer.units, 3);
      expect(c.byId(item.id)!.quantity, 10);
      expect(c.stockByLocation(item.id), {'Warehouse': 7, 'Store Front': 3});
      expectBalanced(c);
    });

    test('it is clamped to what the source bin actually holds', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 4).copyWith(location: 'Warehouse'),
      );

      final transfer = c.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Van',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 99,
          ),
        ],
      )!;

      expect(transfer.lines.single.quantity, 4);
      expect(c.stockByLocation(item.id), {'Van': 4});
      expectBalanced(c);
    });

    test('a source bin with nothing in it moves nothing', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 4).copyWith(location: 'Warehouse'),
      );

      final transfer = c.recordTransfer(
        fromLocation: 'Van',
        toLocation: 'Store Front',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 2,
          ),
        ],
      );

      expect(transfer, isNull);
      expect(c.stockByLocation(item.id), {'Warehouse': 4});
    });

    test('a transfer to the same place is refused', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 4).copyWith(location: 'Warehouse'),
      );

      expect(
        c.recordTransfer(
          fromLocation: 'Warehouse',
          toLocation: 'Warehouse',
          lines: [
            TransferLine(
              id: 't1',
              itemId: item.id,
              itemName: 'Bolt',
              quantity: 2,
            ),
          ],
        ),
        isNull,
      );
    });

    test('it lands in the ledger tagged with the document', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      final transfer = c.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Store Front',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 3,
          ),
        ],
      )!;

      final movement = c.movements.first;
      expect(movement.kind, MovementKind.transfer);
      expect(movement.documentId, transfer.id);
      expect(movement.before, 10);
      expect(
        movement.after,
        10,
        reason: 'the goods have not left the business, only the shelf',
      );
      expect(movement.note, 'Moved 3 from Warehouse to Store Front');
    });

    test('a new destination is folded into the location list', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );

      c.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Overflow Shed',
        lines: [
          TransferLine(
            id: 't1',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 2,
          ),
        ],
      );

      expect(c.settings.locations, contains('Overflow Shed'));
      expect(c.transferLocations, contains('Overflow Shed'));
    });
  });

  group('roll-ups', () {
    test('units and value are counted per location', () async {
      final c = await newController();
      final bolt = c.createItem(
        draft(
          name: 'Bolt',
          quantity: 10,
          unitCost: 100,
        ).copyWith(location: 'Warehouse'),
      );
      c.createItem(
        draft(
          name: 'Nut',
          quantity: 4,
          unitCost: 50,
        ).copyWith(location: 'Store Front'),
      );
      c.recordTransfer(
        fromLocation: 'Warehouse',
        toLocation: 'Store Front',
        lines: [
          TransferLine(
            id: 't1',
            itemId: bolt.id,
            itemName: 'Bolt',
            quantity: 6,
          ),
        ],
      );

      expect(c.unitsByLocation, {'Store Front': 10, 'Warehouse': 4});
      expect(c.valueByLocation['Warehouse'], 400);
      expect(c.valueByLocation['Store Front'], 800);
    });
  });

  group('persistence', () {
    test('the breakdown survives a reload', () async {
      final repo = newRepository();
      final first = await controllerOver(repo);
      final item = first.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );
      first.recordTransfer(
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
        notes: 'Loaded for the Monday round',
      );
      await pumpWrites();

      final second = await controllerOver(repo);

      expect(second.stockByLocation(item.id), {'Warehouse': 6, 'Van': 4});
      expectBalanced(second);
      final transfer = second.transfers.single;
      expect(transfer.reference, 'TR-0001');
      expect(transfer.fromLocation, 'Warehouse');
      expect(transfer.toLocation, 'Van');
      expect(transfer.notes, 'Loaded for the Monday round');
      expect(transfer.lines.single.quantity, 4);

      final ledger = second.movements
          .where((m) => m.kind == MovementKind.transfer)
          .toList();
      expect(
        ledger,
        hasLength(1),
        reason: 'the move must still be in the ledger after a reload',
      );
      expect(ledger.single.documentId, transfer.id);
      expect(ledger.single.note, 'Moved 4 from Warehouse to Van');
    });

    test('a failed ledger write takes the stock change with it', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 10).copyWith(location: 'Warehouse'),
      );
      await pumpWrites();

      // Break the ledger so the movement insert fails partway through the
      // commit. Levels are written before movements, so without a single
      // transaction the stock would move with nothing to explain it — which
      // is exactly what went wrong in the browser.
      await repo.db.customStatement('DROP TABLE movements');

      final now = DateTime.now();
      await expectLater(
        repo.commitStockChange(
          levels: {
            item.id: {'Warehouse': 6, 'Van': 4},
          },
          movements: [
            Movement(
              id: 'm1',
              itemId: item.id,
              itemName: 'Bolt',
              kind: MovementKind.transfer,
              before: 10,
              after: 10,
              at: now,
            ),
          ],
          transfer: Transfer(
            id: 'tr1',
            reference: 'TR-0001',
            fromLocation: 'Warehouse',
            toLocation: 'Van',
            lines: const [
              TransferLine(
                id: 'l1',
                itemId: 'x',
                itemName: 'Bolt',
                quantity: 4,
              ),
            ],
            movedAt: now,
            createdAt: now,
          ),
        ),
        throwsA(anything),
      );

      expect(
        await repo.loadLevels(),
        {
          item.id: {'Warehouse': 10},
        },
        reason: 'stock must not move when its ledger row cannot be written',
      );
    });

    test('the sample catalogue starts balanced', () async {
      final c = await newController(seeded: true);

      expectBalanced(c);
      expect(c.unitsByLocation.values.fold(0, (a, b) => a + b), c.totalUnits);
    });
  });
}
