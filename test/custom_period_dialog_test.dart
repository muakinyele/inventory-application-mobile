import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/custom_period_dialog.dart';

import 'support.dart';

/// Opens the dialog on its own, so the assertions are about the dialog rather
/// than the page that hosts it.
Future<DateTimeRange?> open(
  WidgetTester tester, {
  DateTimeRange? initial,
}) async {
  DateTimeRange? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await showCustomPeriodDialog(
                  context,
                  initial: initial,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('the dialog', () {
    testWidgets('opens as a modal over the page, not a full-screen picker', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await open(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Custom period'), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // A dialog, not a page. The AlertDialog render box is only the layout
      // container and spans the window, so what is measured is the painted
      // surface — the panel the user actually sees.
      final surface = tester.getSize(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(surface.width, lessThan(700));
      expect(surface.height, lessThan(700));
      // And the page it applies to is still behind it, which is the whole
      // point of a modal over a full-screen picker.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('offers the spans people ask for by name', (tester) async {
      await open(tester);

      // Opening cold lands on a sensible default rather than nothing.
      expect(
        tester.getSemantics(find.text('Last 30 days')),
        isSemantics(isSelected: true),
      );

      for (final label in [
        'Last 7 days',
        'Last 30 days',
        'This month',
        'Last month',
        'This quarter',
        'Year to date',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a preset fills both dates and says how long it is', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Last 7 days'));
      await tester.pumpAndSettle();

      expect(find.text('7 days'), findsOneWidget);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('To'), findsOneWidget);
    });

    testWidgets('Apply returns the chosen span, Cancel returns nothing', (
      tester,
    ) async {
      DateTimeRange? applied;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    applied = await showCustomPeriodDialog(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(applied, isNotNull);
      expect(applied!.end.difference(applied!.start).inDays, 6);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(applied, isNull);
    });

    testWidgets('reopening highlights the preset already in force', (
      tester,
    ) async {
      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);
      await open(
        tester,
        initial: DateTimeRange(
          start: day.subtract(const Duration(days: 6)),
          end: day,
        ),
      );

      expect(
        tester.getSemantics(find.text('Last 7 days')),
        isSemantics(isSelected: true),
      );
      // And only that one.
      expect(
        tester.getSemantics(find.text('Last 30 days')),
        isSemantics(isSelected: false),
      );
    });

    testWidgets('last month is a whole month, whatever its length', (
      tester,
    ) async {
      DateTimeRange? applied;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    applied = await showCustomPeriodDialog(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Starts on the 1st and ends on the last day of that month — the guard
      // against a naive "same day last month", which breaks on a short one.
      expect(applied!.start.day, 1);
      final dayAfter = applied!.end.add(const Duration(days: 1));
      expect(dayAfter.day, 1, reason: 'must end on the final day');
      expect(applied!.end.month, isNot(DateTime.now().month));
    });
  });

  group('on the reports page', () {
    testWidgets('choosing Custom opens the modal', (tester) async {
      tester.view.physicalSize = const Size(1280, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController(seeded: true);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/reports'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Custom period'), findsOneWidget);
    });

    testWidgets('applying a span drives the report', (tester) async {
      tester.view.physicalSize = const Size(1280, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await newController(seeded: true);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/reports'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // The dialog is gone and the page is showing the span it returned.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Trading'), findsOneWidget);
      expect(find.textContaining('–'), findsWidgets);
    });
  });
}
