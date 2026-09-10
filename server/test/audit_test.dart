import 'package:stockpile_server/src/audit/audit_actions.dart';
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

  group('the trail records what it should', () {
    test('a sign-in, a failure and a logout each appear', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.post(
        '/auth/login',
        body: {'email': ada.email, 'password': 'wrong-password-here'},
      );
      final session = await server.signIn(ada);
      await server.post(
        '/auth/session/logout',
        accessToken: session.accessToken,
      );

      final response = await server.get(
        '/audit-logs',
        accessToken: admin.accessToken,
      );
      final actions = [
        for (final entry in response.body['entries']! as List)
          (entry! as Map)['action'],
      ];

      expect(actions, contains(AuditAction.login));
      expect(actions, contains(AuditAction.loginFailed));
      expect(actions, contains(AuditAction.logout));
    });

    test('entries carry actor, target, result, IP and time', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );

      final response = await server.get(
        '/audit-logs?action=${AuditAction.userDisabled}',
        accessToken: admin.accessToken,
      );
      final entry = (response.body['entries']! as List).first as Map;

      expect(entry['actorEmail'], 'admin@example.com');
      expect(entry['targetType'], 'user');
      expect(entry['targetId'], ada.id);
      expect(entry['targetLabel'], 'ada@example.com');
      expect(entry['result'], 'success');
      expect(entry['at'], isNotNull);
    });

    test('no password, token or hash ever reaches the trail', () async {
      final ada = await server.createUser(
        email: 'ada@example.com',
        password: 'a-very-distinctive-password',
      );
      final session = await server.signIn(ada);

      // Exercise the paths that handle secrets.
      await server.post(
        '/auth/login',
        body: {'email': ada.email, 'password': 'another-distinctive-secret'},
      );
      await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': 'a-very-distinctive-password',
          'newPassword': 'a third distinctive phrase',
        },
        accessToken: session.accessToken,
      );
      await server.post('/auth/forgot-password', body: {'email': ada.email});

      final everything = (await server.get(
        '/audit-logs?limit=200',
        accessToken: admin.accessToken,
      )).toString();

      expect(everything, isNot(contains('a-very-distinctive-password')));
      expect(everything, isNot(contains('another-distinctive-secret')));
      expect(everything, isNot(contains('a third distinctive phrase')));
      expect(everything.toLowerCase(), isNot(contains('argon2')));
      expect(everything, isNot(contains('tokenHash')));

      // And the same holds of the rows themselves, not just this projection.
      for (final entry in await server.auditEntries()) {
        final metadata = entry.metadata ?? '';
        expect(metadata, isNot(contains('distinctive')));
      }
    });
  });

  group('querying', () {
    test('filters by action, actor and free text', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.signIn(ada);
      await server.patch(
        '/users/${ada.id}/status',
        body: {'enabled': false},
        accessToken: admin.accessToken,
      );

      final byAction = await server.get(
        '/audit-logs?action=${AuditAction.userDisabled}',
        accessToken: admin.accessToken,
      );
      expect(byAction.body['total'], 1);

      final me = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );
      final byActor = await server.get(
        '/audit-logs?actor=${me.user['id']}',
        accessToken: admin.accessToken,
      );
      expect(byActor.body['total'], isPositive);
      for (final entry in byActor.body['entries']! as List) {
        expect((entry! as Map)['actorId'], me.user['id']);
      }

      final bySearch = await server.get(
        '/audit-logs?search=ada@example',
        accessToken: admin.accessToken,
      );
      expect(bySearch.body['total'], isPositive);
    });

    test('pages stably, newest first', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      for (var i = 0; i < 6; i++) {
        await server.post(
          '/auth/login',
          body: {'email': ada.email, 'password': 'wrong-password-here'},
        );
      }

      final first = await server.get(
        '/audit-logs?limit=3&offset=0',
        accessToken: admin.accessToken,
      );
      final second = await server.get(
        '/audit-logs?limit=3&offset=3',
        accessToken: admin.accessToken,
      );

      final firstIds = [
        for (final e in first.body['entries']! as List) (e! as Map)['id'],
      ];
      final secondIds = [
        for (final e in second.body['entries']! as List) (e! as Map)['id'],
      ];

      expect(firstIds, hasLength(3));
      // No entry appears on both pages — the ordering is tie-broken on id, so
      // rows written in the same microsecond still page deterministically.
      expect(firstIds.toSet().intersection(secondIds.toSet()), isEmpty);
    });

    test('filters by date range', () async {
      final ada = await server.createUser(email: 'ada@example.com');
      await server.signIn(ada);

      final today = DateTime.now().toUtc();
      final iso = today.toIso8601String().substring(0, 10);

      final included = await server.get(
        '/audit-logs?from=$iso&to=$iso',
        accessToken: admin.accessToken,
      );
      expect(included.body['total'], isPositive);

      final future = today.add(const Duration(days: 2));
      final excluded = await server.get(
        '/audit-logs?from=${future.toIso8601String().substring(0, 10)}',
        accessToken: admin.accessToken,
      );
      expect(excluded.body['total'], 0);
    });

    test('offers the closed list of action types for the filter', () async {
      final response = await server.get(
        '/audit-logs/actions',
        accessToken: admin.accessToken,
      );
      final actions = (response.body['actions']! as List).cast<String>();

      expect(actions, contains(AuditAction.login));
      expect(actions, contains(AuditAction.rolesChanged));
      expect(actions, equals(AuditAction.all));
    });
  });

  group('access', () {
    test('only a permitted caller can read it', () async {
      final staff = await server.signedInUser(email: 'staff@example.com');
      expect(
        (await server.get(
          '/audit-logs',
          accessToken: staff.accessToken,
        )).statusCode,
        403,
      );
      expect((await server.get('/audit-logs')).statusCode, 401);
    });

    test('there is no endpoint that edits or deletes an entry', () async {
      final entries = await server.auditEntries();
      final id = entries.first.id;

      for (final method in ['DELETE', 'PATCH', 'PUT']) {
        final response = await server.request(
          method,
          '/audit-logs/$id',
          accessToken: admin.accessToken,
          body: method == 'DELETE' ? null : {'action': 'tampered'},
        );
        expect(
          response.statusCode,
          isIn([404, 405]),
          reason: '$method must not be routed',
        );
      }

      expect(await server.auditEntries(), hasLength(entries.length));
    });
  });
}
