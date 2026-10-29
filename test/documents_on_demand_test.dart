import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/data/snapshot.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/document_gate.dart';

import 'fake_inventory_server.dart';

// SIGNING IN FETCHED EVERY DOCUMENT IN THE WORKSPACE. All five collections,
// with every line of every one, before the dashboard — which shows none of
// them — could draw. On a workspace with a few thousand receipts that is the
// whole of the wait people were describing as "invoices take time to load",
// except it was paid at sign-in, for screens they had not opened.
//
// Documents are now the business of whichever screen shows them.

/// A controller as it is after a real sign-in: shared data in hand, no
/// documents.
Future<(InventoryController, FakeInventoryServer)> freshController() async {
  final server = FakeInventoryServer();
  return (
    InventoryController(await fakeInventoryApi(server), Snapshot.empty),
    server,
  );
}

Iterable<String> documentReads(FakeInventoryServer server) =>
    server.calls.where((c) => c.startsWith('GET /api/documents/'));

/// A gate with a trivial page behind it.
Widget gatedPage(InventoryController controller, Set<DocumentSet> need) =>
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        home: DocumentGate(need: need, builder: (_) => const Text('the page')),
      ),
    );

/// Two tabs in an `IndexedStack`, the way the navigation shell holds them:
/// leaving one keeps it mounted and merely offstage.
class _StubShell extends StatefulWidget {
  const _StubShell({required this.need, required this.controller});

  final Set<DocumentSet> need;
  final InventoryController controller;

  @override
  State<_StubShell> createState() => _StubShellState();
}

class _StubShellState extends State<_StubShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < 2; i++)
            TickerMode(
              enabled: i == _index,
              child: i == 0
                  ? DocumentGate(
                      need: widget.need,
                      builder: (_) => const Text('the page'),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      bottomNavigationBar: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: () => setState(() => _index = 1),
            child: const Text('away'),
          ),
          TextButton(
            onPressed: () => setState(() => _index = 0),
            child: const Text('back'),
          ),
        ],
      ),
    );
  }
}

void main() {
  group('a controller that has not been asked for documents', () {
    test('holds none and says so', () async {
      final (controller, server) = await freshController();

      expect(controller.invoices, isEmpty);
      expect(controller.receipts, isEmpty);
      expect(documentReads(server), isEmpty);
      for (final kind in DocumentSet.values) {
        expect(
          controller.documentsReady({kind}),
          isFalse,
          reason: '${kind.name} cannot be ready before it is fetched',
        );
      }
    });
  });

  group('asking for a collection', () {
    test('fetches it and only it', () async {
      final (controller, server) = await freshController();

      await controller.ensureDocuments({DocumentSet.receipts});

      expect(documentReads(server), ['GET /api/documents/receipts']);
      expect(controller.documentsReady({DocumentSet.receipts}), isTrue);
      expect(controller.documentsReady({DocumentSet.invoices}), isFalse);
    });

    test('is paid once, however many times a screen rebuilds', () async {
      final (controller, server) = await freshController();

      await controller.ensureDocuments({DocumentSet.invoices});
      await controller.ensureDocuments({DocumentSet.invoices});
      await controller.ensureDocuments({DocumentSet.invoices});

      expect(documentReads(server), hasLength(1));
    });

    test('two screens at the same moment make one request', () async {
      final (controller, server) = await freshController();

      await Future.wait([
        controller.ensureDocuments({DocumentSet.invoices}),
        controller.ensureDocuments({DocumentSet.invoices}),
      ]);

      expect(documentReads(server), hasLength(1));
    });

    test('a screen that needs several gets them all', () async {
      final (controller, server) = await freshController();

      await controller.ensureDocuments({
        DocumentSet.receipts,
        DocumentSet.invoices,
        DocumentSet.salesOrders,
      });

      expect(documentReads(server), hasLength(3));
      expect(
        controller.documentsReady({
          DocumentSet.receipts,
          DocumentSet.invoices,
          DocumentSet.salesOrders,
        }),
        isTrue,
      );
    });

    test('notifies, so the gate opens without another tap', () async {
      final (controller, _) = await freshController();
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.ensureDocuments({DocumentSet.transfers});

      expect(notified, greaterThan(0));
    });
  });

  // A collection that failed must not be remembered as loaded: that would
  // show an empty Receipts page, with no error, for the rest of the session.
  group('a fetch that fails', () {
    test('is not mistaken for an empty workspace', () async {
      final (controller, server) = await freshController();
      server.failNextReadOf.add('/api/documents/receipts');

      await controller.ensureDocuments({DocumentSet.receipts});

      expect(controller.documentsReady({DocumentSet.receipts}), isFalse);
      expect(controller.documentError({DocumentSet.receipts}), isNotNull);
      // The failure belongs to the collection that failed, not to the app:
      // Invoices must not inherit an error Receipts ran into.
      expect(controller.documentError({DocumentSet.invoices}), isNull);
    });

    test('is retried the next time a screen asks', () async {
      final (controller, server) = await freshController();
      server.failNextReadOf.add('/api/documents/receipts');
      await controller.ensureDocuments({DocumentSet.receipts});

      await controller.ensureDocuments({DocumentSet.receipts});

      expect(documentReads(server), hasLength(2));
      expect(controller.documentsReady({DocumentSet.receipts}), isTrue);
    });
  });

  // A GATE THAT FAILED ONCE SPUN FOR THE REST OF THE SESSION. The navigation
  // shell is an IndexedStack, so leaving a tab only pushes it offstage --
  // `initState` never runs again, and the gate's one and only attempt was the
  // one that failed. No error, no retry, no second request: just a spinner,
  // forever, on a page that had simply missed one fetch.
  group('a gate whose fetch failed', () {
    testWidgets('says so, instead of spinning for ever', (tester) async {
      final (controller, server) = await freshController();
      server.failNextReadOf.add('/api/documents/receipts');

      await tester.pumpWidget(gatedPage(controller, {DocumentSet.receipts}));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Could not load this page'), findsOneWidget);
      expect(find.text('the page'), findsNothing);
    });

    testWidgets('loads the page when the retry lands', (tester) async {
      final (controller, server) = await freshController();
      server.failNextReadOf.add('/api/documents/receipts');
      await tester.pumpWidget(gatedPage(controller, {DocumentSet.receipts}));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('the page'), findsOneWidget);
      expect(documentReads(server), hasLength(2));
    });

    testWidgets('tries again when the tab is opened again', (tester) async {
      // Coming back to the tab is the retry. Without this the only attempt a
      // screen ever makes is its first one.
      final (controller, server) = await freshController();
      server.failNextReadOf.add('/api/documents/receipts');

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            home: _StubShell(
              need: const {DocumentSet.receipts},
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(documentReads(server), hasLength(1));

      // Leave the tab and come back.
      await tester.tap(find.text('away'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('back'));
      await tester.pumpAndSettle();

      expect(
        documentReads(server),
        hasLength(2),
        reason: 'returning to the tab has to try again',
      );
      expect(find.text('the page'), findsOneWidget);
    });
  });

  // The whole shell, not a gate on its own: the branches are what hold the
  // gates, and a route wired to the wrong collection -- or to none -- is a
  // mistake only this notices.
  group('the real navigation shell', () {
    testWidgets('each branch fetches its own documents as it is opened', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (controller, server) = await freshController();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const StockpileApp(initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        documentReads(server),
        isEmpty,
        reason: 'the dashboard reads no documents, so it must wait for none',
      );

      for (final (label, path) in [
        ('Invoices', 'GET /api/documents/invoices'),
        ('Receipts', 'GET /api/documents/receipts'),
        ('Purchase Orders', 'GET /api/documents/purchase-orders'),
        ('Sales Orders', 'GET /api/documents/sales-orders'),
        ('Transfers', 'GET /api/documents/transfers'),
      ]) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(
          documentReads(server),
          contains(path),
          reason: 'opening $label did not fetch what it shows',
        );
      }

      expect(
        documentReads(server),
        hasLength(5),
        reason: 'five screens, five fetches, nothing speculative',
      );
    });
  });

  group('the gate a screen sits behind', () {
    Widget gated(InventoryController controller, Set<DocumentSet> need) =>
        gatedPage(controller, need);

    testWidgets('waits, fetches, then shows the screen', (tester) async {
      final (controller, server) = await freshController();

      await tester.pumpWidget(gated(controller, {DocumentSet.receipts}));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('the page'), findsNothing);

      await tester.pumpAndSettle();

      expect(find.text('the page'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(documentReads(server), ['GET /api/documents/receipts']);
    });

    testWidgets('spends no frame on a spinner the second visit', (
      tester,
    ) async {
      final (controller, server) = await freshController();
      await controller.ensureDocuments({DocumentSet.receipts});

      await tester.pumpWidget(gated(controller, {DocumentSet.receipts}));

      // First frame, before any settling: already there.
      expect(find.text('the page'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpAndSettle();
      expect(documentReads(server), hasLength(1));
    });

    testWidgets('a reload after the page opened does not leave it spinning', (
      tester,
    ) async {
      // A reload forgets every document. The gate had finished waiting, so
      // nothing asked again: an invoice opened just as the app reloaded spun
      // for ever with everything it needed already fetched once.
      final (controller, server) = await freshController();
      await tester.pumpWidget(gated(controller, {DocumentSet.invoices}));
      await tester.pumpAndSettle();
      expect(find.text('the page'), findsOneWidget);

      await controller.reload();
      await tester.pumpAndSettle();

      expect(find.text('the page'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(documentReads(server), hasLength(2), reason: 'asked again once');
    });
  });
}
