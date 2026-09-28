import 'package:flutter/material.dart' hide Durations;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/inventory_status_banner.dart';

import 'package:stockpile/data/snapshot.dart';
import 'package:stockpile/models/party.dart';

import 'fake_inventory_server.dart';
import 'support.dart';

Future<void> _pumpBanner(
  WidgetTester tester,
  InventoryController controller,
) async {
  // The app's own theme: the banner reads its colours from the Palette theme
  // extension, and a bare MaterialApp has none.
  await tester.pumpWidget(
    ChangeNotifierProvider<InventoryController>.value(
      value: controller,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: InventoryStatusBanner()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Supplier supplierDraft() {
  final now = DateTime.now();
  return Supplier(
    id: '',
    name: 'Nexa Components',
    contactName: '',
    phone: '',
    email: '',
    address: '',
    leadTimeDays: 7,
    paymentTerms: '',
    notes: '',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  // A FAILED WRITE WAS THE QUIETEST FAILURE IN THE APP. `lastWriteError` was
  // set in forty-five places and read in none: the optimistic change stayed on
  // screen, the server never heard, and the row came back on the next load
  // with nothing having said so.
  group('a write that failed', () {
    testWidgets('says so, on whatever screen you are on', (tester) async {
      final controller = await newController();
      controller.lastWriteError = Exception('no route to host');

      await _pumpBanner(tester, controller);

      expect(
        find.textContaining('could not be saved'),
        findsOneWidget,
        reason: 'the whole point: it used to say nothing at all',
      );
    });

    testWidgets('says the change is not on the server', (tester) async {
      // Not merely "something went wrong": what matters is that the thing on
      // screen is not saved and will be gone on reload.
      final controller = await newController();
      controller.lastWriteError = Exception('boom');

      await _pumpBanner(tester, controller);

      expect(find.textContaining('has not reached the server'), findsOneWidget);
    });

    testWidgets('can be dismissed, and stays dismissed', (tester) async {
      final controller = await newController();
      controller.lastWriteError = Exception('boom');
      await _pumpBanner(tester, controller);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be saved'), findsNothing);
      expect(controller.lastWriteError, isNull);
    });

    testWidgets('nothing is shown when nothing has failed', (tester) async {
      final controller = await newController();

      await _pumpBanner(tester, controller);

      expect(find.textContaining('could not be saved'), findsNothing);
    });

    testWidgets('a successful write clears an earlier failure', (tester) async {
      final controller = await newController();
      controller.lastWriteError = Exception('boom');
      await _pumpBanner(tester, controller);
      expect(find.textContaining('could not be saved'), findsOneWidget);

      await controller.createItem(draft(name: 'Bolt'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be saved'), findsNothing);
    });
  });

  group('archiving a partner', () {
    test('a refused archive leaves the row where it is', () async {
      // It used to remove the supplier from the list whatever happened: the
      // save swallows its own failure and hands back the payload, so this
      // could not tell a save from a refusal. Gone from the screen, still on
      // the server, back on the next load.
      final server = FakeInventoryServer();
      final controller = InventoryController(
        await fakeInventoryApi(server),
        Snapshot.empty,
      );
      final supplier = await controller.createSupplier(supplierDraft());
      expect(controller.suppliers, hasLength(1));

      server.failNextWrite = true;
      final archived = await controller.archiveSupplier(supplier.id);

      expect(archived, isFalse);
      expect(
        controller.suppliers,
        hasLength(1),
        reason: 'it is still on the server, so it is still on the screen',
      );
      expect(controller.lastWriteError, isNotNull);
    });

    test('an archive that reached the server takes the row away', () async {
      final controller = await newController();
      final supplier = await controller.createSupplier(supplierDraft());

      final archived = await controller.archiveSupplier(supplier.id);

      expect(archived, isTrue);
      expect(controller.suppliers, isEmpty);
    });
  });
}
