import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/state/auth_controller.dart';
import 'package:stockpile/state/inventory_controller.dart';
import 'package:stockpile/ui/widgets/app_sidebar.dart';

import 'auth_support.dart';
import 'package:stockpile/data/seed_data.dart';

import 'support.dart';

/// Tall enough that the whole sidebar list is built.
///
/// The nav is a `ListView`, so at a realistic 900px height the Administration
/// section falls below the fold and is never constructed — which would make
/// every `findsNothing` assertion below pass for the wrong reason.
const _desktop = Size(1280, 1600);

/// Builds the real app with both controllers, so the router's guard, the
/// sidebar and the pages are all exercised together rather than in isolation.
Future<AuthController> _pumpApp(
  WidgetTester tester, {
  required FakeAuthServer server,
  String initialLocation = '/',
  bool signedIn = false,
  Size size = _desktop,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final inventory = await seededController(
    items: seedItems(),
    movements: seedMovements(),
  );
  final (:auth, storage: _) = newAuth(server);

  if (signedIn) {
    await auth.signIn(
      email: 'ada@example.com',
      password: 'correct-horse-battery',
      rememberMe: true,
    );
  } else {
    await auth.restore();
  }

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<InventoryController>.value(value: inventory),
        ChangeNotifierProvider<AuthController>.value(value: auth),
      ],
      child: StockpileApp(initialLocation: initialLocation),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  group('protected routes', () {
    testWidgets('an unauthenticated visitor is sent to sign in', (
      tester,
    ) async {
      await _pumpApp(tester, server: FakeAuthServer());

      expect(find.text('Sign in'), findsWidgets);
      expect(
        find.text('Dashboard'),
        findsNothing,
        reason: 'the app itself must not render behind the sign-in screen',
      );
    });

    testWidgets('a deep link into the app also lands on sign in', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/items',
      );

      expect(find.text('Sign in'), findsWidgets);
    });

    testWidgets('the attempted destination is remembered for after sign-in', (
      tester,
    ) async {
      final auth = await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/reports',
      );

      expect(auth.pendingRedirect, '/reports');
    });

    testWidgets('signing in reaches the app', (tester) async {
      await _pumpApp(tester, server: FakeAuthServer(), signedIn: true);

      expect(find.text('Dashboard'), findsWidgets);
      expect(find.text('Sign in'), findsNothing);
    });

    testWidgets('a signed-in user is redirected away from the sign-in screen', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        signedIn: true,
        initialLocation: '/login',
      );

      // Which is also what stops the browser's back button landing on a live
      // sign-in page behind an active session.
      expect(find.text('Dashboard'), findsWidgets);
    });

    testWidgets('signing out returns to the sign-in screen', (tester) async {
      final auth = await _pumpApp(
        tester,
        server: FakeAuthServer(),
        signedIn: true,
      );
      expect(find.text('Dashboard'), findsWidgets);

      await auth.signOut();
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsWidgets);
      expect(find.text('Dashboard'), findsNothing);
    });

    testWidgets('an expired session moves the app to sign in on its own', (
      tester,
    ) async {
      final server = FakeAuthServer();
      final auth = await _pumpApp(tester, server: server, signedIn: true);

      // The server forgets the session, as it would after a password change
      // elsewhere or an administrator revoking the device.
      server.expireNextAccess = true;
      server.refreshFails = true;
      await auth.refreshUser();
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsWidgets);
    });
  });

  group('the public routes stay reachable', () {
    testWidgets('forgot password', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/forgot-password',
      );
      expect(find.text('Reset your password'), findsWidgets);
    });

    testWidgets('reset password with a token', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/reset-password?token=abc',
      );
      expect(find.text('Choose a new password'), findsWidgets);
    });

    testWidgets('reset password without a token explains itself', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/reset-password',
      );
      expect(find.text('This link is not valid'), findsWidgets);
      expect(find.text('Request a new link'), findsWidgets);
    });
  });

  group('role-based navigation', () {
    testWidgets('staff see no administration destinations', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(
          permissions: const ['items.view'],
          roles: const ['staff'],
        ),
        signedIn: true,
      );

      expect(find.text('Users'), findsNothing);
      expect(find.text('Audit Log'), findsNothing);
      expect(find.text('Items'), findsWidgets, reason: 'the app still works');
    });

    testWidgets('an administrator sees them', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(
          permissions: const ['items.view', 'users.view', 'audit_logs.view'],
          roles: const ['administrator'],
        ),
        signedIn: true,
      );

      expect(find.text('Users'), findsWidgets);
      expect(find.text('Audit Log'), findsWidgets);
    });

    testWidgets('the admin nav appears only with its own permission', (
      tester,
    ) async {
      // users.view but not audit_logs.view: one shows, the other does not.
      await _pumpApp(
        tester,
        server: FakeAuthServer(
          permissions: const ['items.view', 'users.view'],
          roles: const ['administrator'],
        ),
        signedIn: true,
      );

      expect(find.text('Users'), findsWidgets);
      expect(find.text('Audit Log'), findsNothing);
    });

    testWidgets('typing a URL you lack permission for gets you nowhere', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(
          permissions: const ['items.view'],
          roles: const ['staff'],
        ),
        signedIn: true,
        initialLocation: '/users',
      );

      // Bounced to the dashboard. The API refuses the same request anyway.
      expect(find.text('Dashboard'), findsWidgets);
      expect(find.text('Invite'), findsNothing);
    });

    testWidgets('every gated destination names the permission it needs', (
      tester,
    ) async {
      for (final item in navItems.where((i) => i.permission != null)) {
        expect(item.permission, isNotEmpty);
      }
      expect(
        navItems.where((i) => i.permission != null).map((i) => i.route),
        containsAll(['/users', '/audit-logs']),
      );
    });
  });

  group('my account', () {
    testWidgets('is reachable and shows the signed-in user', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        signedIn: true,
        initialLocation: '/account',
      );

      expect(find.text('My account'), findsWidgets);
      expect(find.text('ada@example.com'), findsWidgets);
      expect(find.text('Ada Lovelace'), findsWidgets);
    });

    testWidgets('the role is shown but not editable', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        signedIn: true,
        initialLocation: '/account',
      );

      expect(find.text('Role'), findsWidgets);
      expect(
        find.text(
          'Only an administrator can change your role. Ask one if '
          'you need different access.',
        ),
        findsWidgets,
      );
    });

    testWidgets('needs a session like anything else', (tester) async {
      await _pumpApp(
        tester,
        server: FakeAuthServer(),
        initialLocation: '/account',
      );
      expect(find.text('Sign in'), findsWidgets);
    });
  });
}
