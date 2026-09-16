import 'package:flutter/material.dart' hide Durations;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/inventory_status_banner.dart';

import 'package:stockpile/data/seed_data.dart';

import 'support.dart';

Future<InventoryController> _shared() async {
  // A controller with no API is the on-device path; these assertions are about
  // the shared one, so it is built through the harness and then driven
  // directly. What the banner reads is the controller's state, not the wire.
  return newController();
}

Future<void> _pump(WidgetTester tester, InventoryController controller) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<InventoryController>.value(
      value: controller,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: InventoryStatusBanner()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('on device the banner says nothing at all', (tester) async {
    // Nothing to report: the data is there before the first frame and there is
    // no server to be out of step with.
    final controller = await _shared();
    await _pump(tester, controller);

    expect(find.byType(Material), findsWidgets);
    expect(find.textContaining('inventory'), findsNothing);
  });

  group('state the banner has to make visible', () {
    test('a fresh controller has asked for nothing yet', () async {
      final controller = await _shared();
      expect(controller.load, InventoryLoad.idle);
      expect(controller.loadError, isNull);
      expect(controller.stockConflict, isNull);
    });

    test('reload does nothing without a server to ask', () async {
      // The on-device path has no load to be in the middle of, so this stays
      // idle rather than pretending to fetch.
      final controller = await _shared();
      await controller.reload();
      expect(controller.load, InventoryLoad.idle);
    });

    test('forgetting is a no-op on device', () async {
      // The local catalogue belongs to the device, not the session: signing
      // out must not empty it.
      final controller = await seededController(
        items: seedItems(),
        movements: seedMovements(),
      );
      final before = controller.items.length;
      expect(before, greaterThan(0));

      controller.forgetSharedData();

      expect(controller.items.length, before);
    });
  });
}
