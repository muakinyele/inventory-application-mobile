import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/models/transfer.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'package:stockpile/data/seed_data.dart';

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
    test('deleting an item drops its bins', () async {
      final c = await newController();
      final item = await c.createItem(draft(name: 'Bolt', quantity: 10));

      await c.deleteItem(item.id);

      expect(c.stockByLocation(item.id), isEmpty);
      expect(c.unitsByLocation, isEmpty);
    });
  });

  group('draining', () {});

  group('transfers', () {
    test('a transfer to the same place is refused', () async {
      final c = await newController();
      final item = await c.createItem(
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
  });

  group('roll-ups', () {});

  group('persistence', () {});
}
