import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/app_message.dart';

/// Opens the message on its own, so the assertions are about the modal rather
/// than the page that raised it.
Future<void> open(
  WidgetTester tester,
  String message, {
  MessageTone tone = MessageTone.success,
  MessageAction? action,
  VoidCallback? onClosed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                await showAppMessage(
                  context,
                  message,
                  tone: tone,
                  action: action,
                );
                onClosed?.call();
              },
              child: const Text('raise'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('raise'));
  await tester.pumpAndSettle();
}

void main() {
  group('app message', () {
    testWidgets('reports the outcome in a modal, not along the bottom', (
      tester,
    ) async {
      await open(tester, 'Backup exported');

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Backup exported'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a warning reads as one', (tester) async {
      await open(tester, 'Nothing to export yet.', tone: MessageTone.warning);

      expect(find.text('Heads up'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('a failure reads as one', (tester) async {
      await open(
        tester,
        'That file could not be read.',
        tone: MessageTone.failure,
      );

      expect(find.text('That did not work'), findsOneWidget);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    });

    testWidgets('a caller-supplied title replaces the tone heading', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showAppMessage(context, 'Saved', title: 'Stocktake'),
                  child: const Text('raise'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('raise'));
      await tester.pumpAndSettle();

      expect(find.text('Stocktake'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('dismissing completes the future', (tester) async {
      var closed = false;
      await open(tester, 'Draft saved', onClosed: () => closed = true);

      expect(closed, isFalse);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the action runs and takes the modal down with it', (
      tester,
    ) async {
      var undone = false;
      await open(
        tester,
        'Bolt: +1 pcs',
        action: MessageAction(label: 'Undo', onPressed: () => undone = true),
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(undone, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
