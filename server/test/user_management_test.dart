import 'package:stockpile_server/src/audit/audit_actions.dart';
import 'package:stockpile_server/src/auth/token_store.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;
  late TestSession admin;

  setUp(() async {
    server = await TestServer.start();
    admin = await server.signedInUser(
      email: 'admin@example.com',
      role: administratorRoleKey,
    );
  });
  tearDown(() async => server.close());

  group('invitation', () {
    test('creates a pending account and mails a link', () async {
      final response = await server.post(
        '/users',
        body: {
          'email': 'ada@example.com',
          'name': 'Ada Lovelace',
          'roles': [inventoryManagerRoleKey],
        },
        accessToken: admin.accessToken,
      );

      expect(response.statusCode, 201);
      expect(response.user['status'], 'pending');
      expect(response.user['emailVerified'], false);
      expect(response.user['roles'], [inventoryManagerRoleKey]);

      final mail = server.mailer.lastTo('ada@example.com');
      expect(mail, isNotNull);
      expect(mail!.subject, contains('invited'));
      expect(mail.text, contains('accept-invitation?token='));
    });

    test('a pending account cannot sign in', () async {
      await server.post(
        '/users',
        body: {
          'email': 'ada@example.com',
          'name': 'Ada',
          'roles': [staffRoleKey],
        },
        accessToken: admin.accessToken,
      );

      final response = await server.post(
        '/auth/login',
        body: {'email': 'ada@example.com', 'password': 'anything at all'},
      );
      expect(response.statusCode, isIn([401, 403]));
    });

    test('accepting it sets the password, activates and verifies', () async {
      await server.post(
        '/users',
        body: {
          'email': 'ada@example.com',
          'name': 'Ada',
          'roles': [staffRoleKey],
        },
        accessToken: admin.accessToken,
      );
      final token = server.tokenFromMailTo('ada@example.com');

      final accepted = await server.post(
        '/auth/accept-invitation',
        body: {'token': token, 'password': 'a brand new passphrase'},
      );
      expect(accepted.statusCode, 200);

      final signIn = await server.post(
        '/auth/login',
        body: {
          'email': 'ada@example.com',
          'password': 'a brand new passphrase',
        },
      );
      expect(signIn.statusCode, 200);
      expect(signIn.user['status'], 'active');
      // Receiving the link is itself proof the address works.
      expect(signIn.user['emailVerified'], true);
    });

    test('an invitation is single-use', () async {
      await server.post(
        '/users',
        body: {'email': 'ada@example.com', 'name': 'Ada', 'roles': []},
        accessToken: admin.accessToken,
      );
      final token = server.tokenFromMailTo('ada@example.com');

      await server.post(
        '/auth/accept-invitation',
        body: {'token': token, 'password': 'a brand new passphrase'},
      );
      final second = await server.post(
        '/auth/accept-invitation',
        body: {'token': token, 'password': 'a different passphrase'},
      );

      expect(second.statusCode, 400);
      expect(second.errorCode, 'token_used');
    });

    test('an expired invitation is refused', () async {
      final created = await server.post(
        '/users',
        body: {'email': 'ada@example.com', 'name': 'Ada', 'roles': []},
        accessToken: admin.accessToken,
      );
      final token = server.tokenFromMailTo('ada@example.com');
      await server.expireTokensFor(
        created.user['id']! as String,
        TokenPurpose.invitation,
      );

      final response = await server.post(
        '/auth/accept-invitation',
        body: {'token': token, 'password': 'a brand new passphrase'},
      );
      expect(response.errorCode, 'token_expired');
    });

    test(
      'the invitation lookup shows who it is for, and nothing more',
      () async {
        await server.post(
          '/users',
          body: {
            'email': 'ada@example.com',
            'name': 'Ada',
            'roles': [administratorRoleKey],
          },
          accessToken: admin.accessToken,
        );
        final token = server.tokenFromMailTo('ada@example.com');

        final response = await server.get('/auth/invitation?token=$token');
        expect(response.statusCode, 200);
        expect(response.body['email'], 'ada@example.com');
        expect(response.body['name'], 'Ada');
        // No id, status or roles leak to an unauthenticated caller.
        expect(response.body.keys, unorderedEquals(['email', 'name']));
      },
    );

    test('two accounts cannot share an address', () async {
      await server.createUser(email: 'ada@example.com');
      final response = await server.post(
        '/users',
        body: {'email': 'ADA@example.com', 'name': 'Ada', 'roles': []},
        accessToken: admin.accessToken,
      );

      expect(response.statusCode, 409);
      expect(response.errorCode, 'email_in_use');
    });

    test('a revoked invitation stops working', () async {
      final created = await server.post(
        '/users',
        body: {'email': 'ada@example.com', 'name': 'Ada', 'roles': []},
        accessToken: admin.accessToken,
      );
      final token = server.tokenFromMailTo('ada@example.com');

      await server.delete(
        '/users/${created.user['id']}/invitation',
        accessToken: admin.accessToken,
      );

      final response = await server.post(
        '/auth/accept-invitation',
        body: {'token': token, 'password': 'a brand new passphrase'},
      );
      expect(response.statusCode, 400);
    });
  });

  group('listing', () {
    test('searches, filters and pages', () async {
      await server.createUser(email: 'ada@example.com', name: 'Ada Lovelace');
      await server.createUser(
        email: 'grace@example.com',
        name: 'Grace Hopper',
        role: inventoryManagerRoleKey,
      );
      await server.createUser(email: 'alan@example.com', name: 'Alan Turing');

      final all = await server.get('/users', accessToken: admin.accessToken);
      expect(all.body['total'], 4); // three plus the admin

      final searched = await server.get(
        '/users?search=grace',
        accessToken: admin.accessToken,
      );
      expect(searched.body['total'], 1);
      expect((searched.body['users']! as List).single, isA<Map>());

      final byRole = await server.get(
        '/users?role=$inventoryManagerRoleKey',
        accessToken: admin.accessToken,
      );
      expect(byRole.body['total'], 1);

      final paged = await server.get(
        '/users?limit=2&offset=0',
        accessToken: admin.accessToken,
      );
      expect((paged.body['users']! as List), hasLength(2));
      expect(paged.body['total'], 4);
    });

    test('an absurd limit is clamped rather than obeyed', () async {
      final response = await server.get(
        '/users?limit=999999',
        accessToken: admin.accessToken,
      );
      expect(response.statusCode, 200);
      expect((response.body['users']! as List).length, lessThanOrEqualTo(100));
    });

    test('the list never carries a password hash', () async {
      await server.createUser(email: 'ada@example.com');
      final response = await server.get(
        '/users',
        accessToken: admin.accessToken,
      );

      expect(response.toString().toLowerCase(), isNot(contains('argon2')));
      for (final user in response.body['users']! as List) {
        expect((user! as Map).keys, isNot(contains('passwordHash')));
      }
    });
  });

  group('status', () {
    test('disabling notifies the user and blocks sign-in', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      server.mailer.clear();

      final response = await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );
      expect(response.statusCode, 200);
      expect(response.user['status'], 'disabled');

      expect(
        server.mailer.lastTo('ada@example.com')!.subject,
        contains('disabled'),
      );
      expect(
        (await server.post(
          '/auth/login',
          body: {'email': ada.email, 'password': ada.password},
        )).errorCode,
        'account_disabled',
      );
    });

    test('re-enabling restores access and says so', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );
      server.mailer.clear();

      final response = await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': true},
        accessToken: admin.accessToken,
      );
      expect(response.user['status'], 'active');
      expect(
        server.mailer.lastTo('ada@example.com')!.subject,
        contains('restored'),
      );

      final signIn = await server.post(
        '/auth/login',
        body: {'email': ada.email, 'password': ada.password},
      );
      expect(signIn.statusCode, 200);
    });

    test('an administrator cannot disable themselves', () async {
      final me = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );
      final response = await server.patch(
        '/users/${me.user['id']}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );

      expect(response.statusCode, 409);
      expect(response.errorCode, 'cannot_target_self');
    });

    test('the last administrator cannot be disabled by anyone', () async {
      // Give someone else the power to try it.
      final other = await server.createUser(email: 'other@example.com');
      await server.patch(
        '/users/${other.id}/permissions',
        body: {
          'permissions': {'users.disable': true},
        },
        accessToken: admin.accessToken,
      );
      final otherSession = await server.signIn(other);
      final me = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );

      final response = await server.patch(
        '/users/${me.user['id']}/status',
        body: {'enabled': false},
        accessToken: otherSession.accessToken,
      );
      expect(response.errorCode, 'last_administrator');
    });
  });

  group('deactivation', () {
    test('is a soft delete that frees the address for re-use', () async {
      final ada = await server.createUser(email: 'ada@example.com');

      final deleted = await server.delete(
        '/users/${ada.id}',
        accessToken: admin.accessToken,
      );
      expect(deleted.statusCode, 200);

      // Gone from the list.
      final list = await server.get('/users', accessToken: admin.accessToken);
      final emails = [
        for (final user in list.body['users']! as List) (user! as Map)['email'],
      ];
      expect(emails, isNot(contains('ada@example.com')));

      // But the row survives, so the audit trail still names a real person.
      expect(await server.userRow(ada.id), isNotNull);

      // And the address can be invited again.
      final reinvited = await server.post(
        '/users',
        body: {'email': 'ada@example.com', 'name': 'Ada Again', 'roles': []},
        accessToken: admin.accessToken,
      );
      expect(reinvited.statusCode, 201);
    });

    test('signs the account out immediately', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(ada);

      await server.delete('/users/${ada.id}', accessToken: admin.accessToken);

      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: session.accessToken,
        )).statusCode,
        401,
      );
    });
  });

  group('unlock', () {
    test('an administrator can lift a lockout early', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      for (var attempt = 0; attempt < 3; attempt++) {
        await server.post(
          '/auth/login',
          body: {'email': ada.email, 'password': 'wrong-password-here'},
        );
      }
      expect(
        (await server.post(
          '/auth/login',
          body: {'email': ada.email, 'password': ada.password},
        )).errorCode,
        'account_locked',
      );

      final unlocked = await server.post(
        '/users/${ada.id}/unlock',
        accessToken: admin.accessToken,
      );
      expect(unlocked.statusCode, 200);

      expect(
        (await server.post(
          '/auth/login',
          body: {'email': ada.email, 'password': ada.password},
        )).statusCode,
        200,
      );
    });
  });

  group('audit', () {
    test('administrative actions are recorded with actor and target', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );

      final entries = await server.auditEntries(
        action: AuditAction.userDisabled,
      );
      expect(entries, hasLength(1));
      expect(entries.single.actorEmail, 'admin@example.com');
      expect(entries.single.targetId, ada.id);
      expect(entries.single.targetLabel, 'ada@example.com');
    });
  });
}
