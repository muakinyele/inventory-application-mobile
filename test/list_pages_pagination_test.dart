import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

const _desktop = Size(1400, 3000);

Future<void> _pump(
  WidgetTester tester,
  InventoryController controller,
  String location,
) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: StockpileApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
}

Supplier _supplier(int i) {
  final now = DateTime.now();
  return Supplier(
    id: 's$i',
    name: 'Supplier ${i.toString().padLeft(3, '0')}',
    contactName: 'Contact $i',
    phone: '0800${i.toString().padLeft(4, '0')}',
    email: 'supplier$i@example.com',
    address: 'Unit $i',
    leadTimeDays: 3,
    paymentTerms: '30 days',
    notes: '',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('list pages that had no search at all', () {
    testWidgets('suppliers pages, and says how many there are', (tester) async {
      final controller = await seededController(
        suppliers: [for (var i = 0; i < 120; i++) _supplier(i)],
      );

      await _pump(tester, controller, '/suppliers');

      expect(find.textContaining('Showing 1–50 of 120 suppliers'), findsOne);
      expect(find.text('Supplier 000'), findsOneWidget);
      expect(
        find.text('Supplier 050'),
        findsNothing,
        reason: 'the next page holds it',
      );
    });

    testWidgets('suppliers can be searched', (tester) async {
      final controller = await seededController(
        suppliers: [for (var i = 0; i < 120; i++) _supplier(i)],
      );
      await _pump(tester, controller, '/suppliers');

      await tester.enterText(find.byType(TextField).first, 'Supplier 042');
      await tester.pumpAndSettle();

      expect(find.textContaining('Showing 1–1 of 1'), findsOneWidget);
    });

    testWidgets('searching a supplier by email finds it', (tester) async {
      // The point of naming the searchable fields per page: a phone number or
      // an address is how somebody actually looks a supplier up.
      final controller = await seededController(
        suppliers: [for (var i = 0; i < 30; i++) _supplier(i)],
      );
      await _pump(tester, controller, '/suppliers');

      await tester.enterText(
        find.byType(TextField).first,
        'supplier17@example.com',
      );
      await tester.pumpAndSettle();

      expect(find.text('Supplier 017'), findsOneWidget);
      expect(find.textContaining('Showing 1–1 of 1'), findsOneWidget);
    });

    testWidgets('an empty page shows its own empty state, not a search box', (
      tester,
    ) async {
      // A search field over nothing is furniture. The page should say there
      // is nothing and offer the way to make one.
      final controller = await seededController(suppliers: const []);

      await _pump(tester, controller, '/suppliers');

      expect(find.text('No suppliers yet'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a supplier search matching nothing says so', (tester) async {
      final controller = await seededController(
        suppliers: [for (var i = 0; i < 30; i++) _supplier(i)],
      );
      await _pump(tester, controller, '/suppliers');

      await tester.enterText(find.byType(TextField).first, 'zzzzz');
      await tester.pumpAndSettle();

      expect(find.text('Nothing matches'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);
    });

    testWidgets('clearing the search brings the list back', (tester) async {
      final controller = await seededController(
        suppliers: [for (var i = 0; i < 30; i++) _supplier(i)],
      );
      await _pump(tester, controller, '/suppliers');

      await tester.enterText(find.byType(TextField).first, 'zzzzz');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Showing 1–30 of 30'), findsOneWidget);
    });
  });
}
