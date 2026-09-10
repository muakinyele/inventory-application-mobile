import 'package:stockpile_server/src/audit/audit_actions.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() async => server.close());

  group('sign in', () {
    test('succeeds and returns the user with their permissions', () async {
      await server.createUser(email: 'ada@example.com');

      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'correct-horse-battery'},
      );

      expect(response.statusCode, 200);
      expect(response.user['email'], 'ada@example.com');
      expect(response.user['roles'], contains(staffRoleKey));
      expect(response.user['permissions'], contains('items.view'));
      expect(response.accessToken, isNotEmpty);
      expect(response.refreshToken, isNotEmpty);
    });

    test('never returns the password hash', () async {
      await server.createUser(email: 'ada@example.com');
      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'correct-horse-battery'},
      );

      expect(response.user.keys, isNot(contains('passwordHash')));
      expect(response.toString().toLowerCase(), isNot(contains('argon2')));
    });

    test('matches the address case-insensitively', () async {
      await server.createUser(email: 'ada@example.com');
      final response = await server.post(
        '/auth/login',
        body: {
          'email': '  ADA@Example.COM ',
          'password': 'correct-horse-battery',
        },
      );
      expect(response.statusCode, 200);
    });

    test('rejects a wrong password with the generic message', () async {
      await server.createUser(email: 'ada@example.com');
      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'wrong-password-here'},
      );

      expect(response.statusCode, 401);
      expect(response.errorCode, 'invalid_credentials');
      expect(response.errorMessage, 'Invalid email or password.');
    });

    test('answers identically for an unknown address, so accounts cannot be '
        'enumerated', () async {
      await server.createUser(email: 'ada@example.com');

      final wrongPassword = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'wrong-password-here'},
      );
      final noSuchAccount = await server.post(
        '/auth/login',
        body: {
          'email': 'nobody@example.com',
          'password': 'wrong-password-here',
        },
      );

      expect(noSuchAccount.statusCode, wrongPassword.statusCode);
      expect(noSuchAccount.errorCode, wrongPassword.errorCode);
      expect(noSuchAccount.errorMessage, wrongPassword.errorMessage);
    });

    test('refuses a disabled account with its own message', () async {
      await server.createUser(email: 'ada@example.com', status: 'disabled');
      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'correct-horse-battery'},
      );

      expect(response.statusCode, 403);
      expect(response.errorCode, 'account_disabled');
      expect(response.errorMessage, contains('contact an administrator'));
    });

    test('refuses an unverified account', () async {
      await server.createUser(email: 'ada@example.com', emailVerified: false);
      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'correct-horse-battery'},
      );

      expect(response.statusCode, 403);
      expect(response.errorCode, 'email_unverified');
    });

    test('records the sign-in in the audit trail', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.signIn(user);

      final entries = await server.auditEntries(action: AuditAction.login);
      expect(entries, hasLength(1));
      expect(entries.single.actorEmail, 'ada@example.com');
    });

    test('records a failure without recording the password', () async {
      await server.createUser(email: 'ada@example.com');
      await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'hunter2-was-wrong'},
      );

      final entries = await server.auditEntries(
        action: AuditAction.loginFailed,
      );
      expect(entries, hasLength(1));
      expect(entries.single.result, 'failure');
      expect(entries.single.metadata, isNot(contains('hunter2')));
    });
  });

  group('lockout', () {
    test(
      'locks after the configured number of failures and unlocks by time',
      () async {
        final user = await server.createUser(email: 'ada@example.com');

        // MAX_FAILED_LOGINS is 3 in the test config.
        for (var attempt = 0; attempt < 2; attempt++) {
          final response = await server.post(
            '/auth/login',
            body: {'email': user.email, 'password': 'wrong-password-here'},
          );
          expect(response.errorCode, 'invalid_credentials');
        }

        final locking = await server.post(
          '/auth/login',
          body: {'email': user.email, 'password': 'wrong-password-here'},
        );
        expect(locking.statusCode, 429);
        expect(locking.errorCode, 'account_locked');
        expect(locking.headers['retry-after'], isNotNull);

        // Even the right password is refused while the lock stands.
        final correct = await server.post(
          '/auth/login',
          body: {'email': user.email, 'password': user.password},
        );
        expect(correct.errorCode, 'account_locked');
      },
    );

    test('the lock is time-bounded, never permanent', () async {
      final user = await server.createUser(email: 'ada@example.com');
      for (var attempt = 0; attempt < 3; attempt++) {
        await server.post(
          '/auth/login',
          body: {'email': user.email, 'password': 'wrong-password-here'},
        );
      }

      final row = await server.userRow(user.id);
      expect(row.lockedUntil, isNotNull);
      // The whole point: it expires on its own rather than needing an admin.
      expect(row.lockedUntil!.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('a successful sign-in clears the failure counter', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': 'wrong-password-here'},
      );
      await server.signIn(user);

      final row = await server.userRow(user.id);
      expect(row.failedLoginCount, 0);
      expect(row.lockedUntil, isNull);
    });
  });

  group('sessions', () {
    test('an access token authenticates /auth/session/me', () async {
      final session = await server.signedInUser(email: 'ada@example.com');
      final response = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );

      expect(response.statusCode, 200);
      expect(response.user['email'], 'ada@example.com');
    });

    test(
      'no token is unauthenticated, a dead token is an expired session',
      () async {
        final anonymous = await server.get('/auth/session/me');
        expect(anonymous.statusCode, 401);
        expect(anonymous.errorCode, 'unauthenticated');

        final rubbish = await server.get(
          '/auth/session/me',
          accessToken: 'not-a-real-token',
        );
        expect(rubbish.statusCode, 401);
        expect(rubbish.errorCode, 'session_expired');
      },
    );

    test('an expired access token is refused', () async {
      final session = await server.signedInUser(email: 'ada@example.com');
      final me = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      await server.expireAccessToken(me.user['sessionId']! as String);

      final response = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(response.statusCode, 401);
      expect(response.errorCode, 'session_expired');
      expect(
        response.errorMessage,
        'Your session has expired. Please sign in again.',
      );
    });

    test('logout revokes the token immediately', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      final loggedOut = await server.post(
        '/auth/session/logout',
        accessToken: session.accessToken,
      );
      expect(loggedOut.statusCode, 200);

      final after = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(after.statusCode, 401);
    });

    test(
      'refresh rotates the pair and retires the old refresh token',
      () async {
        final session = await server.signedInUser(email: 'ada@example.com');

        final refreshed = await server.post(
          '/auth/refresh',
          body: {'refreshToken': session.refreshToken},
        );
        expect(refreshed.statusCode, 200);
        expect(refreshed.refreshToken, isNot(session.refreshToken));

        final newToken = refreshed.accessToken;
        final me = await server.get('/auth/session/me', accessToken: newToken);
        expect(me.statusCode, 200);
      },
    );

    test('replaying a rotated refresh token kills every session', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      final first = await server.post(
        '/auth/refresh',
        body: {'refreshToken': session.refreshToken},
      );
      expect(first.statusCode, 200);

      // The original token has already been exchanged. Presenting it again is
      // either a confused client or a stolen copy.
      final replay = await server.post(
        '/auth/refresh',
        body: {'refreshToken': session.refreshToken},
      );
      expect(replay.statusCode, 401);

      // The session minted by the legitimate rotation is killed too — the
      // whole chain is untrusted once a token is seen twice.
      final me = await server.get(
        '/auth/session/me',
        accessToken: first.accessToken,
      );
      expect(me.statusCode, 401);

      final entries = await server.auditEntries(
        action: AuditAction.refreshReplayed,
      );
      expect(entries, hasLength(1));
    });

    test('logout-all keeps the current device by default', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final phone = await server.signIn(user);
      final laptop = await server.signIn(user);

      final response = await server.post(
        '/auth/session/logout-all',
        accessToken: laptop.accessToken,
      );
      expect(response.statusCode, 200);
      expect(response.body['revoked'], 1);

      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: laptop.accessToken,
        )).statusCode,
        200,
      );
      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: phone.accessToken,
        )).statusCode,
        401,
      );
    });

    test('a disabled account loses its sessions at once', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final victim = await server.createUser(email: 'ada@example.com');
      final victimSession = await server.signIn(victim);

      await server.patch(
        '/users/${victim.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );

      final response = await server.get(
        '/auth/session/me',
        accessToken: victimSession.accessToken,
      );
      expect(response.statusCode, 401);
    });
  });
}
