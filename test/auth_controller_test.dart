import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/state/auth_controller.dart';

import 'auth_support.dart';

void main() {
  group('signing in', () {
    test('stores the session and exposes the user', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);

      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      expect(auth.isAuthenticated, isTrue);
      expect(auth.user!.email, 'ada@example.com');
      expect(await storage.read(), isNotNull);
    });

    test('a wrong password leaves the app signed out', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);

      await expectLater(
        auth.signIn(
          email: 'ada@example.com',
          password: 'wrong-password',
          rememberMe: true,
        ),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.code, 'code', 'invalid_credentials')
              .having(
                (e) => e.message,
                'message',
                'Invalid email or password.',
              ),
        ),
      );

      expect(auth.isAuthenticated, isFalse);
      expect(auth.isBusy, isFalse);
      expect(await storage.read(), isNull, reason: 'nothing to remember');
    });

    test('"remember me" off keeps the session out of storage', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);

      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: false,
      );

      expect(auth.isAuthenticated, isTrue, reason: 'signed in for this run');
      expect(
        await storage.read(),
        isNull,
        reason: 'but nothing survives the app closing',
      );
    });

    test('notifies listeners so the router can re-evaluate', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);

      var notifications = 0;
      auth.addListener(() => notifications++);

      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      expect(notifications, greaterThan(0));
    });
  });

  group('restoring a session', () {
    test('signs in from stored tokens', () async {
      final server = FakeAuthServer();
      final storage = InMemoryTokenStorage();

      // A first run signs in and leaves tokens behind.
      final first = newAuth(server, storage: storage);
      await first.auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      // A second run, as if the app had been reopened.
      final second = newAuth(server, storage: storage);
      expect(second.auth.isRestoring, isTrue);

      await second.auth.restore();

      expect(second.auth.isAuthenticated, isTrue);
      expect(second.auth.user!.email, 'ada@example.com');
    });

    test(
      'with nothing stored, lands signed out without calling the API',
      () async {
        final server = FakeAuthServer();
        final (:auth, storage: _) = newAuth(server);

        await auth.restore();

        expect(auth.status, AuthStatus.signedOut);
        expect(
          server.calls,
          isEmpty,
          reason: 'no token means nothing to verify',
        );
      },
    );

    test(
      'verifies with the server rather than trusting the stored token',
      () async {
        final server = FakeAuthServer();
        final storage = InMemoryTokenStorage();
        final first = newAuth(server, storage: storage);
        await first.auth.signIn(
          email: 'ada@example.com',
          password: 'correct-horse-battery',
          rememberMe: true,
        );

        // The account was disabled while the app was closed: both the token and
        // a refresh are refused.
        server.liveAccessTokens.clear();
        server.refreshFails = true;

        final second = newAuth(server, storage: storage);
        await second.auth.restore();

        expect(second.auth.isAuthenticated, isFalse);
        expect(
          await storage.read(),
          isNull,
          reason: 'a session the server rejects must not be kept',
        );
      },
    );

    test(
      'being offline at launch does not sign you in on stale tokens',
      () async {
        final server = FakeAuthServer();
        final storage = InMemoryTokenStorage();
        final first = newAuth(server, storage: storage);
        await first.auth.signIn(
          email: 'ada@example.com',
          password: 'correct-horse-battery',
          rememberMe: true,
        );

        server.offline = true;
        final second = newAuth(server, storage: storage);
        await second.auth.restore();

        expect(second.auth.isAuthenticated, isFalse);
        expect(second.auth.endedReason, contains('Could not reach the server'));
      },
    );
  });

  group('token refresh', () {
    test(
      'an expired access token is renewed and the request retried',
      () async {
        final server = FakeAuthServer();
        final (:auth, storage: _) = newAuth(server);
        await auth.signIn(
          email: 'ada@example.com',
          password: 'correct-horse-battery',
          rememberMe: true,
        );
        server.calls.clear();

        server.expireNextAccess = true;
        final user = await auth.api.me();

        expect(user.email, 'ada@example.com');
        expect(server.calls, [
          'GET /auth/session/me',
          'POST /auth/refresh',
          'GET /auth/session/me',
        ], reason: 'the 401 should trigger one refresh and one retry');
      },
    );

    test('the rotated refresh token replaces the stored one', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );
      final original = (await storage.read())!.refreshToken;

      server.expireNextAccess = true;
      await auth.api.me();

      final stored = (await storage.read())!;
      expect(stored.refreshToken, isNot(original));
      // Keeping the old one would trip the server's replay detection on the
      // next renewal and kill the whole session.
      expect(server.liveRefreshTokens, contains(stored.refreshToken));
      expect(server.liveRefreshTokens, isNot(contains(original)));
    });

    test('a failed refresh drops the app to signed out', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      server.expireNextAccess = true;
      server.refreshFails = true;

      await expectLater(auth.api.me(), throwsA(isA<AuthApiException>()));

      expect(auth.isAuthenticated, isFalse);
      expect(
        auth.endedReason,
        'Your session has expired. Please sign in again.',
      );
      expect(await storage.read(), isNull);
    });

    test('parallel requests share one refresh rather than racing', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );
      server.calls.clear();
      server.expireNextAccess = true;

      await Future.wait([auth.api.me(), auth.api.me(), auth.api.me()]);

      expect(
        server.calls.where((c) => c == 'POST /auth/refresh').length,
        1,
        reason: 'a burst of 401s must not fire a refresh each',
      );
    });
  });

  group('signing out', () {
    test('clears the session, the stored tokens and the user', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      await auth.signOut();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.user, isNull);
      expect(await storage.read(), isNull);
      expect(server.calls, contains('POST /auth/session/logout'));
    });

    test(
      'still signs you out locally when the server cannot be reached',
      () async {
        final server = FakeAuthServer();
        final (:auth, :storage) = newAuth(server);
        await auth.signIn(
          email: 'ada@example.com',
          password: 'correct-horse-battery',
          rememberMe: true,
        );

        server.offline = true;
        await auth.signOut();

        expect(auth.isAuthenticated, isFalse);
        expect(
          await storage.read(),
          isNull,
          reason: 'pressing sign out must always sign you out',
        );
      },
    );
  });

  group('permissions', () {
    test('reflect what the server granted', () async {
      final server = FakeAuthServer(
        permissions: ['items.view', 'inventory.adjust'],
        roles: ['staff'],
      );
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      expect(auth.can('items.view'), isTrue);
      expect(auth.can('inventory.adjust'), isTrue);
      expect(auth.can('users.view'), isFalse);
      expect(auth.canAny(['users.view', 'items.view']), isTrue);
      expect(auth.canAny(['users.view', 'audit_logs.view']), isFalse);
      expect(auth.hasRole('staff'), isTrue);
      expect(auth.hasRole('administrator'), isFalse);
    });

    test('a signed-out controller grants nothing', () {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);

      expect(auth.can('items.view'), isFalse);
      expect(auth.permissions, isEmpty);
      expect(auth.roles, isEmpty);
    });
  });

  group('password change', () {
    test('a wrong current password is reported as such', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      await expectLater(
        auth.changePassword(
          currentPassword: 'not-it',
          newPassword: 'a whole new passphrase',
        ),
        throwsA(
          isA<AuthApiException>().having(
            (e) => e.code,
            'code',
            'wrong_current_password',
          ),
        ),
      );
      expect(auth.isAuthenticated, isTrue, reason: 'still signed in');
    });

    test('a weak password comes back with the reasons', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      await expectLater(
        auth.changePassword(
          currentPassword: 'correct-horse-battery',
          newPassword: 'short',
        ),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.code, 'code', 'weak_password')
              .having((e) => e.details, 'details', isNotEmpty),
        ),
      );
    });

    test('a successful change keeps this device signed in', () async {
      final server = FakeAuthServer();
      final (:auth, :storage) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );
      final before = (await storage.read())!.accessToken;

      await auth.changePassword(
        currentPassword: 'correct-horse-battery',
        newPassword: 'a whole new passphrase',
      );

      final after = (await storage.read())!.accessToken;
      expect(auth.isAuthenticated, isTrue);
      expect(
        after,
        isNot(before),
        reason: 'the replacement session issued by the server is stored',
      );
    });
  });

  group('errors', () {
    test('a network failure is reported as one, not as a sign-out', () async {
      final server = FakeAuthServer()..offline = true;
      final (:auth, storage: _) = newAuth(server);

      await expectLater(
        auth.signIn(
          email: 'ada@example.com',
          password: 'correct-horse-battery',
          rememberMe: true,
        ),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.isNetworkError, 'isNetworkError', isTrue)
              .having(
                (e) => e.message,
                'message',
                contains('Could not reach the server'),
              ),
        ),
      );
    });

    test('the bearer token is attached to authenticated requests', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );
      server.authHeaders.clear();

      await auth.api.me();

      expect(server.authHeaders.single, startsWith('Bearer '));
    });

    test('identifies itself to the server on mobile', () async {
      // On a Dart VM this header is allowed and gives the security screen a
      // real device label. The browser forbids it — see web_safety_test.dart,
      // which asserts the other half of this.
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);
      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      expect(server.sentHeaders.first['user-agent'], 'Stockpile/1.0');
    });

    test('sign-in itself carries no bearer token', () async {
      final server = FakeAuthServer();
      final (:auth, storage: _) = newAuth(server);

      await auth.signIn(
        email: 'ada@example.com',
        password: 'correct-horse-battery',
        rememberMe: true,
      );

      expect(server.authHeaders.first, isNull);
    });
  });

  group('the API base URL', () {
    AuthApi apiWith(String baseUrl) =>
        AuthApi(baseUrl: baseUrl, storage: InMemoryTokenStorage());

    test('an absolute base is used unchanged', () {
      // What the Android and iOS builds pass: there is no page origin for
      // them to resolve against.
      expect(
        apiWith(
          'https://api.example.com',
        ).endpointFor('/auth/login').toString(),
        'https://api.example.com/auth/login',
      );
      expect(
        apiWith('http://localhost:8081').endpointFor('/auth/me').toString(),
        'http://localhost:8081/auth/me',
      );
    });

    test(
      'a relative base resolves against wherever the app was served from',
      () {
        // What the container image is built with. On the VM `Uri.base` is the
        // working directory; in a browser it is the page — either way the point
        // is that the result is absolute and carries the origin.
        final resolved = apiWith('/api').endpointFor('/auth/login');

        expect(
          resolved.hasScheme,
          isTrue,
          reason: 'must be absolute to be sent',
        );
        expect(resolved.path, endsWith('/api/auth/login'));
      },
    );

    test('query strings survive resolution', () {
      final resolved = apiWith(
        '/api',
      ).endpointFor('/auth/invitation?token=abc');
      expect(resolved.queryParameters['token'], 'abc');
    });
  });
}
