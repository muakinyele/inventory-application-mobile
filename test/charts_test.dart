import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/charts.dart';
import 'package:stockpile/ui/widgets/section_card.dart';

Widget host(Widget child, double width) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(
    body: SizedBox(
      width: width,
      child: SingleChildScrollView(child: child),
    ),
  ),
);

CategoryDonutChart donut({
  required double total,
  required List<double> values,
}) {
  const colors = [
    Colors.grey,
    Colors.orange,
    Colors.blue,
    Colors.deepOrange,
    Colors.purple,
  ];
  return CategoryDonutChart(
    slices: [
      for (final (index, value) in values.indexed)
        ChartSlice(
          label: 'Category ${index + 1}',
          value: value,
          color: colors[index % colors.length],
        ),
    ],
    total: total,
    // Full precision, as the reports page uses — the compact form would hide
    // the very overflow this is guarding against.
    formatValue: (v) => '₦${v.toStringAsFixed(2)}',
    centerLabel: 'Total value',
  );
}

void main() {
  group('donut', () {
    // The regression: a six-figure inventory total is far wider than a fixed
    // centre hole, so it used to spill across the arcs and collide with the
    // slice labels, and a long legend figure wrapped mid-number.
    for (final width in [320.0, 358.0, 480.0, 620.0]) {
      testWidgets('a long total fits the hole at ${width.round()}pt wide', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          host(
            SectionCard(
              title: 'Share of stock value',
              trailing: const Text('% of total'),
              child: donut(
                total: 12295409.09,
                values: [8500000, 1664000, 1097909.09, 596400, 437100],
              ),
            ),
            width,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(CategoryDonutChart), findsOneWidget);
      });
    }

    testWidgets('the centre value is fitted to the hole, not left to run', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(donut(total: 12295409.09, values: [8500000, 3795409.09]), 400),
      );
      await tester.pumpAndSettle();

      final value = find.text('₦12295409.09');
      expect(value, findsOneWidget);

      // This is the mechanism the fix turns on, and the part a widget test
      // can actually see. The overlap itself was text drawn over a painted
      // arc — canvas, invisible to the framework — so what is asserted here is
      // that the total can no longer be wider than the box it sits in,
      // whatever the currency or the size of the business.
      final fitted = find.ancestor(of: value, matching: find.byType(FittedBox));
      expect(
        fitted,
        findsOneWidget,
        reason: 'the total must be fitted, not free to overflow the hole',
      );

      // Visual bounds, transform included: scaled down to fit rather than
      // spilling past its box or being cut to an ellipsis.
      expect(
        tester.getRect(value).width,
        lessThanOrEqualTo(tester.getSize(fitted).width + 0.5),
      );
      expect(find.textContaining('…'), findsNothing);
    });

    testWidgets('a long legend figure stays on one line', (tester) async {
      tester.view.physicalSize = const Size(420, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(donut(total: 12295409.09, values: [8500000, 3795409.09]), 420),
      );
      await tester.pumpAndSettle();

      // The figure that used to break across two lines, splitting the number
      // in half. One line means a box no taller than its own leading.
      final legendValue = find.text('₦3795409.09');
      expect(legendValue, findsOneWidget);
      expect(tester.getSize(legendValue).height, lessThan(24));
    });

    testWidgets('a title with a long caption does not squeeze itself out', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // What actually broke the card: an unconstrained trailing caption wider
      // than the row pushed the title to zero width, wrapping it one letter
      // per line and overflowing.
      await tester.pumpWidget(
        host(
          const SectionCard(
            title: 'Revenue by source',
            trailing: Text('after discount, before tax and everything else'),
            child: Text('body'),
          ),
          360,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Revenue by source'), findsOneWidget);
    });
  });
}
