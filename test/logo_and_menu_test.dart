import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/data/inventory_loader.dart';
import 'package:stockpile/data/snapshot.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/page_header.dart';
import 'package:stockpile/ui/widgets/shell_drawer.dart';

import 'fake_inventory_server.dart';
import 'support.dart';

const _phone = Size(430, 932);
const _desktop = Size(1400, 1200);

void main() {
  // THE LOGO WAS NEVER SENT AND NEVER READ. Setting it updated the controller
  // and the screen, so it looked saved — and it was, in memory. It survived
  // until the next load and was then simply gone, which from the outside looks
  // like signing out deletes your logo.
  group('the company logo', () {
    test('is written to the server when it is set', () async {
      final server = FakeInventoryServer();
      final controller = InventoryController(
        await fakeInventoryApi(server),
        Snapshot.empty,
      );

      await controller.updateSettings(
        controller.settings.copyWith(companyLogo: 'BASE64LOGO'),
      );

      final sent = server.lastPreferences;
      expect(
        sent,
        isNotNull,
        reason: 'the settings write has to reach the server at all',
      );
      expect(sent!['companyLogo'], 'BASE64LOGO');
    });

    test('is read back when the workspace loads', () async {
      // The other half. Writing it without reading it is the same bug with an
      // extra round trip.
      final server = FakeInventoryServer()
        ..preferences = {'companyLogo': 'BASE64LOGO', 'companyName': 'Acme'};

      final snapshot = await loadSharedSnapshot(await fakeInventoryApi(server));

      expect(snapshot.settings.companyLogo, 'BASE64LOGO');
      expect(snapshot.settings.companyName, 'Acme');
    });

    test('an absent logo loads as none rather than throwing', () async {
      final server = FakeInventoryServer()..preferences = {};

      final snapshot = await loadSharedSnapshot(await fakeInventoryApi(server));

      expect(snapshot.settings.companyLogo, '');
      expect(snapshot.settings.hasCompanyLogo, isFalse);
    });
  });

  // THE MENU BUTTON TOOK THE TAP AND DID NOTHING. Every page builds its own
  // Scaffold, and the drawer is on the shell's — so `Scaffold.of(context)`
  // from inside the header found a Scaffold with no drawer, where
  // `openDrawer()` is a silent no-op.
  group('the navigation menu on a phone', () {
    testWidgets('the button opens the shell drawer', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: await seededController(),
          child: const StockpileApp(initialLocation: '/items'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open navigation'), findsOneWidget);
      await tester.tap(find.byTooltip('Open navigation'));
      await tester.pumpAndSettle();

      expect(
        find.byType(Drawer),
        findsOneWidget,
        reason: 'the drawer is what the button is for',
      );
    });

    testWidgets('the drawer lists somewhere to go', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: await seededController(),
          child: const StockpileApp(initialLocation: '/items'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation'));
      await tester.pumpAndSettle();

      expect(find.text('Suppliers'), findsWidgets);
    });

    testWidgets('there is no button when the sidebar is already shown', (
      tester,
    ) async {
      tester.view.physicalSize = _desktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: await seededController(),
          child: const StockpileApp(initialLocation: '/items'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open navigation'), findsNothing);
    });

    testWidgets('a header with no shell above it shows no button', (
      tester,
    ) async {
      // Rather than one that takes the tap and does nothing, which is what
      // this used to be everywhere.
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          // The app's own theme: PageHeader reads its colours from the
          // Palette extension, and a bare MaterialApp carries none.
          theme: buildTheme(Brightness.light),
          home: const Scaffold(
            body: PageHeader(title: 'On its own', actions: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open navigation'), findsNothing);
      expect(find.text('On its own'), findsOneWidget);
    });

    testWidgets('ShellDrawer.of is null without a shell', (tester) async {
      VoidCallback? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = ShellDrawer.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(seen, isNull);
    });
  });
}
