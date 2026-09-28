import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/pagination.dart';

import 'support.dart';

const _desktop = Size(1400, 2600);

/// A catalogue bigger than one page, so paging is actually exercised.
Future<InventoryController> _withItems(int count) {
  final now = DateTime.now();
  return seededController(
    items: [
      for (var i = 0; i < count; i++)
        Item(
          // Built rather than drafted: `copyWith` deliberately has no `id`,
          // and these need distinct ones to render as distinct rows.
          id: 'i$i',
          name: 'Item ${i.toString().padLeft(3, '0')}',
          sku: 'SKU$i',
          category: i.isEven ? 'Parts' : 'Packaging',
          quantity: 10,
          unitCost: 2,
          createdAt: now,
          updatedAt: now,
        ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, InventoryController controller) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: const StockpileApp(initialLocation: '/items'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the items list pages', () {
    testWidgets('it says how much of the catalogue is on screen', (
      tester,
    ) async {
      // The defect underneath all of this: a list that showed part of the
      // catalogue and said nothing about the rest.
      await _pump(tester, await _withItems(120));

      expect(find.textContaining('Showing 1–50 of 120'), findsOneWidget);
    });

    testWidgets('it shows a page, not the whole catalogue', (tester) async {
      await _pump(tester, await _withItems(120));

      expect(find.text('Item 000'), findsOneWidget);
      expect(find.text('Item 049'), findsOneWidget);
      expect(
        find.text('Item 050'),
        findsNothing,
        reason: 'row 51 belongs to the next page',
      );
    });

    testWidgets('the next page shows the next rows', (tester) async {
      await _pump(tester, await _withItems(120));

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();

      expect(find.text('Item 050'), findsOneWidget);
      expect(find.text('Item 000'), findsNothing);
      expect(find.textContaining('Showing 51–100 of 120'), findsOneWidget);
    });

    testWidgets('the last page is short rather than padded', (tester) async {
      await _pump(tester, await _withItems(120));

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Showing 101–120 of 120'), findsOneWidget);

      // Tapping past the end does nothing, rather than scrolling off into
      // an empty page.
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Showing 101–120 of 120'), findsOneWidget);
    });

    testWidgets('choosing more rows per page shows more of them', (
      tester,
    ) async {
      await _pump(tester, await _withItems(120));

      await tester.tap(find.byTooltip('Rows per page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('100').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('Showing 1–100 of 120'), findsOneWidget);
      expect(find.text('Item 099'), findsOneWidget);
    });

    testWidgets('a small catalogue offers no paging at all', (tester) async {
      await _pump(tester, await _withItems(8));

      expect(find.textContaining('Showing 1–8 of 8'), findsOneWidget);
      expect(
        find.byTooltip('Next page'),
        findsNothing,
        reason: 'one page needs no stepper',
      );
    });

    // THE ONE THAT MATTERS. Searching from page 3 used to leave the cursor
    // where it was, so a search with a handful of matches rendered an empty
    // page and read as "nothing found".
    testWidgets('searching from a later page comes back to the first', (
      tester,
    ) async {
      await _pump(tester, await _withItems(120));

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Showing 51–100'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Item 007');
      await tester.pumpAndSettle();

      // Twice: the row, and the search field still holding what was typed.
      expect(find.text('Item 007'), findsNWidgets(2));
      expect(find.textContaining('Showing 1–1 of 1'), findsOneWidget);
    });

    testWidgets('a narrowed list says what it is narrowed from', (
      tester,
    ) async {
      await _pump(tester, await _withItems(120));

      await tester.enterText(find.byType(TextField).first, 'Item 01');
      await tester.pumpAndSettle();

      // 'Item 010'–'Item 019' match.
      expect(find.textContaining('(120 in total)'), findsOneWidget);
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      await _pump(tester, await _withItems(120));

      await tester.enterText(find.byType(TextField).first, 'nothing here');
      await tester.pumpAndSettle();

      expect(find.text('Nothing matches'), findsOneWidget);
    });

    testWidgets('the bar is there for a page-sized catalogue too', (
      tester,
    ) async {
      // Exactly one page: still worth saying how many there are.
      await _pump(tester, await _withItems(50));

      expect(find.byType(PaginationBar), findsOneWidget);
      expect(find.textContaining('Showing 1–50 of 50'), findsOneWidget);
    });
  });
}
