import 'package:flutter/material.dart' hide Durations;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/app_sidebar.dart';

/// Pumps the rail on its own, so these assert the widget's own behaviour
/// rather than the whole app's routing.
Future<void> _pumpRail(
  WidgetTester tester, {
  required bool collapsed,
  VoidCallback? onToggle,
  bool Function(String)? can,
  int alertCount = 0,
  int selectedIndex = 0,
  Set<String> collapsedSections = const {},
  ValueChanged<String>? onToggleSection,
}) async {
  tester.view
    ..physicalSize = const Size(1280, 1600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Row(
          children: [
            AppSidebar(
              selectedIndex: selectedIndex,
              onSelect: (_) {},
              workspaceName: 'My Inventory',
              can: can ?? (_) => true,
              alertCount: alertCount,
              collapsed: collapsed,
              onToggleCollapsed: onToggle,
              collapsedSections: collapsedSections,
              onToggleSection: onToggleSection,
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('expanded', () {
    testWidgets('shows labels, headings and the workspace name', (
      tester,
    ) async {
      await _pumpRail(tester, collapsed: false, onToggle: () {});

      expect(find.text('My Inventory'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Items'), findsOneWidget);
      expect(find.text('STOCK'), findsOneWidget);
      expect(find.text('ADMINISTRATION'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('is the full width', (tester) async {
      await _pumpRail(tester, collapsed: false, onToggle: () {});

      final rail = tester.getSize(find.byType(AppSidebar));
      expect(rail.width, sidebarExpandedWidth);
    });
  });

  group('collapsed', () {
    testWidgets('drops every label but keeps every destination', (
      tester,
    ) async {
      await _pumpRail(tester, collapsed: true, onToggle: () {});

      // No text at all — not the labels, not the headings, not the workspace.
      expect(find.text('Dashboard'), findsNothing);
      expect(find.text('Items'), findsNothing);
      expect(find.text('STOCK'), findsNothing);
      expect(find.text('ADMINISTRATION'), findsNothing);
      expect(find.text('My Inventory'), findsNothing);

      // But the destinations are all still there, as icons.
      for (final item in navItems) {
        expect(
          find.byIcon(item.icon),
          findsWidgets,
          reason: '${item.label} must remain reachable when collapsed',
        );
      }
      expect(find.byIcon(settingsItem.icon), findsWidgets);
      expect(find.byIcon(accountItem.icon), findsWidgets);
    });

    testWidgets('is narrower', (tester) async {
      await _pumpRail(tester, collapsed: true, onToggle: () {});

      final rail = tester.getSize(find.byType(AppSidebar));
      expect(rail.width, sidebarCollapsedWidth);
      expect(rail.width, lessThan(sidebarExpandedWidth));
    });

    testWidgets(
      'names each destination in a tooltip, since nothing else does',
      (tester) async {
        await _pumpRail(tester, collapsed: true, onToggle: () {});

        for (final label in ['Dashboard', 'Items', 'Reports', 'Settings']) {
          expect(
            find.byTooltip(label),
            findsOneWidget,
            reason: 'hovering is the only way to read "$label" when collapsed',
          );
        }
      },
    );

    testWidgets('keeps the reorder count on the alerts icon', (tester) async {
      await _pumpRail(tester, collapsed: true, onToggle: () {}, alertCount: 7);

      // The count rides the icon rather than vanishing with the label.
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('still hides destinations the user cannot reach', (
      tester,
    ) async {
      await _pumpRail(
        tester,
        collapsed: true,
        onToggle: () {},
        can: (permission) => false,
      );

      for (final item in navItems.where((i) => i.permission != null)) {
        expect(
          find.byIcon(item.icon),
          findsNothing,
          reason: '${item.label} needs ${item.permission}',
        );
      }
    });
  });

  group('the toggle', () {
    testWidgets('says what it will do, in both states', (tester) async {
      await _pumpRail(tester, collapsed: false, onToggle: () {});
      expect(find.byTooltip('Collapse menu'), findsOneWidget);

      await _pumpRail(tester, collapsed: true, onToggle: () {});
      expect(find.byTooltip('Expand menu'), findsOneWidget);
    });

    testWidgets('reports a tap', (tester) async {
      var taps = 0;
      await _pumpRail(tester, collapsed: false, onToggle: () => taps++);

      await tester.tap(find.byTooltip('Collapse menu'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('is absent when collapsing is not offered', (tester) async {
      // The drawer presentation passes no callback: it is already a temporary
      // overlay at full width, so there is nothing to collapse.
      await _pumpRail(tester, collapsed: false);

      expect(find.byTooltip('Collapse menu'), findsNothing);
      expect(find.byTooltip('Expand menu'), findsNothing);
    });
  });

  group('the choice is remembered', () {
    testWidgets('across launches', (tester) async {
      SharedPreferences.setMockInitialValues({
        'stockpile.sidebarCollapsed': true,
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('stockpile.sidebarCollapsed'), isTrue);

      // And writing it back is what the shell does on toggle.
      await prefs.setBool('stockpile.sidebarCollapsed', false);
      expect(prefs.getBool('stockpile.sidebarCollapsed'), isFalse);
    });
  });

  group('folding a section', () {
    /// Index of the first destination under a given heading.
    int firstIndexIn(String section) =>
        navItems.indexWhere((i) => i.section == section);

    testWidgets('hides its destinations but keeps the heading', (tester) async {
      await _pumpRail(
        tester,
        collapsed: false,
        collapsedSections: const {'Stock'},
        onToggleSection: (_) {},
      );

      expect(find.text('STOCK'), findsOneWidget, reason: 'still foldable');
      for (final item in navItems.where((i) => i.section == 'Stock')) {
        expect(find.text(item.label), findsNothing);
      }
      // Other sections are untouched.
      expect(find.text('Purchase Orders'), findsOneWidget);
      expect(find.text('Reports'), findsOneWidget);
      // And so is the destination that belongs to no section.
      expect(find.text('Dashboard'), findsOneWidget);
    });

    testWidgets('several can be folded at once', (tester) async {
      await _pumpRail(
        tester,
        collapsed: false,
        collapsedSections: const {'Stock', 'Buying', 'Selling'},
        onToggleSection: (_) {},
      );

      expect(find.text('Items'), findsNothing);
      expect(find.text('Suppliers'), findsNothing);
      expect(find.text('Invoices'), findsNothing);
      expect(find.text('Reports'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
    });

    testWidgets('tapping the heading reports which one', (tester) async {
      final toggled = <String>[];
      await _pumpRail(tester, collapsed: false, onToggleSection: toggled.add);

      await tester.tap(find.text('BUYING'));
      await tester.pumpAndSettle();

      expect(toggled, ['Buying']);
    });

    testWidgets('the section holding the current page stays open', (
      tester,
    ) async {
      // Selected destination is under Selling, and Selling is folded. It has
      // to show anyway, or the rail would claim nothing is selected.
      await _pumpRail(
        tester,
        collapsed: false,
        selectedIndex: firstIndexIn('Selling'),
        collapsedSections: const {'Selling', 'Stock'},
        onToggleSection: (_) {},
      );

      expect(find.text('Sales Orders'), findsOneWidget);
      // The fold still applies to every other folded section.
      expect(find.text('Items'), findsNothing);
    });

    testWidgets('folding is ignored while the rail is collapsed to icons', (
      tester,
    ) async {
      // There are no headings to fold under, so hiding destinations would
      // just make them unreachable.
      await _pumpRail(
        tester,
        collapsed: true,
        collapsedSections: const {'Stock', 'Buying', 'Selling'},
        onToggleSection: (_) {},
      );

      for (final item in navItems) {
        expect(
          find.byIcon(item.icon),
          findsWidgets,
          reason: '${item.label} must stay reachable',
        );
      }
    });

    testWidgets(
      'headings are plain labels when nothing can remember the state',
      (tester) async {
        await _pumpRail(tester, collapsed: false, onToggleSection: null);

        expect(find.text('STOCK'), findsOneWidget);
        expect(find.text('Items'), findsOneWidget, reason: 'nothing is folded');
        // No chevron, because there is nothing to toggle.
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      },
    );

    testWidgets('an open section shows a chevron per heading', (tester) async {
      await _pumpRail(tester, collapsed: false, onToggleSection: (_) {});

      final sections = navItems
          .map((i) => i.section)
          .whereType<String>()
          .toSet();
      expect(
        find.byIcon(Icons.keyboard_arrow_down_rounded),
        findsNWidgets(sections.length),
      );
    });
  });
}
