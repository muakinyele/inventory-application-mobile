import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/state/auth_controller.dart';
import 'package:stockpile/ui/auth/login_page.dart';
import 'package:stockpile/ui/auth/password_field.dart';

import 'auth_support.dart';

Future<AuthController> _pumpLogin(
  WidgetTester tester,
  FakeAuthServer server,
) async {
  final (:auth, storage: _) = newAuth(server);
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthController>.value(
      value: auth,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const LoginPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  group('the sign-in form', () {
    testWidgets('offers everything §2 asks for', (tester) async {
      await _pumpLogin(tester, FakeAuthServer());

      expect(find.text('Email address'), findsWidgets);
      expect(find.text('Password'), findsWidgets);
      expect(find.text('Remember me'), findsWidgets);
      expect(find.text('Forgot password?'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('validates before it calls the server', (tester) async {
      final server = FakeAuthServer();
      await _pumpLogin(tester, server);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      expect(server.calls, isEmpty, reason: 'nothing to send yet');
    });

    testWidgets('shows the server error without leaking which part was wrong', (
      tester,
    ) async {
      await _pumpLogin(tester, FakeAuthServer());

      await tester.enterText(
        find.byType(TextFormField).first,
        'ada@example.com',
      );
      await tester.enterText(find.byType(TextFormField).last, 'wrong-password');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid email or password.'), findsOneWidget);
      // The form stays filled in so the user can correct it.
      expect(find.text('ada@example.com'), findsOneWidget);
    });

    testWidgets('a network failure says so rather than blaming the password', (
      tester,
    ) async {
      final server = FakeAuthServer()..offline = true;
      await _pumpLogin(tester, server);

      await tester.enterText(
        find.byType(TextFormField).first,
        'ada@example.com',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'correct-horse-battery',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach the server'), findsOneWidget);
    });

    testWidgets('signs in on valid details', (tester) async {
      final server = FakeAuthServer();
      final auth = await _pumpLogin(tester, server);

      await tester.enterText(
        find.byType(TextFormField).first,
        'ada@example.com',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'correct-horse-battery',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      // Not `pumpAndSettle`: on success the button keeps its spinner because
      // the app is expected to route away, which a standalone page cannot do.
      // Settling would therefore wait forever.
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(auth.isAuthenticated, isTrue);
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: 'the button stays busy until the router takes over',
      );
    });

    testWidgets('"remember me" is on by default and can be turned off', (
      tester,
    ) async {
      await _pumpLogin(tester, FakeAuthServer());

      Checkbox box() => tester.widget<Checkbox>(find.byType(Checkbox));
      expect(box().value, isTrue);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(box().value, isFalse);
    });
  });

  group('the password field', () {
    testWidgets('hides the password and can reveal it', (tester) async {
      await _pumpLogin(tester, FakeAuthServer());

      TextField field() => tester.widget<TextField>(
        find.descendant(
          of: find.byType(PasswordField),
          matching: find.byType(TextField),
        ),
      );

      expect(field().obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(field().obscureText, isFalse);

      await tester.tap(find.byTooltip('Hide password'));
      await tester.pumpAndSettle();
      expect(field().obscureText, isTrue);
    });

    testWidgets('shows no strength meter when entering an existing password', (
      tester,
    ) async {
      await _pumpLogin(tester, FakeAuthServer());
      expect(find.byType(PasswordStrengthMeter), findsNothing);
    });

    testWidgets('shows one when choosing a new password', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: PasswordField(
              controller: TextEditingController(),
              showStrength: true,
            ),
          ),
        ),
      );

      expect(find.byType(PasswordStrengthMeter), findsOneWidget);
      expect(
        find.textContaining('At least $minPasswordLength characters'),
        findsOneWidget,
        reason: 'the rule that actually gates submission must be stated',
      );
    });
  });

  group('the strength score', () {
    test('rewards length over punctuation', () {
      // A long passphrase of plain words beats a short one with a symbol in
      // it, which is the whole point of the policy.
      expect(
        PasswordStrengthMeter.score('correct horse battery staple'),
        greaterThan(PasswordStrengthMeter.score('Xk9!aQ2z')),
      );
    });

    test('scores a common password at zero however long', () {
      expect(PasswordStrengthMeter.score('password123'), 0);
      expect(PasswordStrengthMeter.score('stockpile123'), 0);
    });

    test('scores anything under the minimum at zero', () {
      expect(PasswordStrengthMeter.score('short'), 0);
      expect(PasswordStrengthMeter.score('a' * (minPasswordLength - 1)), 0);
    });

    test('penalises sequences and repetition', () {
      expect(
        PasswordStrengthMeter.score('abcdefghijkl'),
        lessThan(PasswordStrengthMeter.score('thistlewood market')),
      );
    });

    test('a strong passphrase reaches the top segment', () {
      expect(PasswordStrengthMeter.score('correct horse battery staple'), 4);
    });
  });
}
