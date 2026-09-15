import 'package:flutter/material.dart' hide Durations;
import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/app_sidebar.dart';
import 'package:stockpile/ui/widgets/confirm_dialog.dart';

/// Pumps the rail alone, so these assert the control's own behaviour rather
/// than the whole app's routing.
Future<void> _pumpRail(
  WidgetTester tester, {
  VoidCallback? onSignOut,
  bool collapsed = false,
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
              selectedIndex: 0,
              onSelect: (_) {},
              workspaceName: 'My Inventory',
              can: (_) => true,
              alertCount: 0,
              collapsed: collapsed,
              onToggleCollapsed: () {},
              collapsedSections: const {},
              onToggleSection: (_) {},
              onSignOut: onSignOut,
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
  testWidgets('the rail offers a way to sign out', (tester) async {
    var taps = 0;
    await _pumpRail(tester, onSignOut: () => taps++);

    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('no session in scope, nothing to sign out of', (tester) async {
    // The shell passes null when there is no AuthController, which is what a
    // widget test without authentication looks like. Showing the control there
    // would offer an action that cannot work.
    await _pumpRail(tester, onSignOut: null);

    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('collapsed, the label survives as a tooltip', (tester) async {
    // Collapsed the icon is all that is drawn, so without the tooltip the
    // control is unlabelled — and this one is not safe to press to find out.
    await _pumpRail(tester, onSignOut: () {}, collapsed: true);

    expect(find.text('Sign out'), findsNothing);
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message)
        .toList();
    expect(tooltips, contains('Sign out'));
  });

  group('confirmAction', () {
    Future<bool?> pumpAndAnswer(WidgetTester tester, String? press) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  answer = await confirmAction(
                    context,
                    title: 'Sign out?',
                    body: 'You will need to sign in again on this device.',
                    confirmLabel: 'Sign out',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (press != null) {
        await tester.tap(find.text(press).last);
        await tester.pumpAndSettle();
      }
      return answer;
    }

    testWidgets('confirming returns true', (tester) async {
      expect(await pumpAndAnswer(tester, 'Sign out'), isTrue);
    });

    testWidgets('cancelling returns false', (tester) async {
      expect(await pumpAndAnswer(tester, 'Cancel'), isFalse);
    });

    testWidgets('dismissing without answering is a refusal', (tester) async {
      // A dialog tapped away rather than answered must not read as consent.
      await pumpAndAnswer(tester, null);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsNothing);
    });
  });
}
