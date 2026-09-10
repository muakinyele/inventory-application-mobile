import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() async => server.close());

  group('roles carry the permissions they claim', () {
    test('an administrator holds every permission in the catalogue', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final response = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );

      final held = (response.user['permissions']! as List).cast<String>();
      expect(held, containsAll(allPermissions.map((p) => p.key)));
    });

    test('a manager runs inventory but cannot administer users', () async {
      final manager = await server.signedInUser(
        email: 'manager@example.com',
        role: inventoryManagerRoleKey,
      );
      final held =
          ((await server.get(
                    '/auth/session/me',
                    accessToken: manager.accessToken,
                  )).user['permissions']!
                  as List)
              .cast<String>();

      expect(held, contains('items.create'));
      expect(held, contains('inventory.adjust'));
      expect(held, contains('purchase_orders.create'));
      expect(held, isNot(contains('users.create')));
      expect(held, isNot(contains('audit_logs.view')));
      expect(held, isNot(contains('settings.manage')));
    });

    test('staff can look and record movements, not delete or price', () async {
      final staff = await server.signedInUser(email: 'staff@example.com');
      final held =
          ((await server.get(
                    '/auth/session/me',
                    accessToken: staff.accessToken,
                  )).user['permissions']!
                  as List)
              .cast<String>();

      expect(held, contains('items.view'));
      expect(held, contains('inventory.adjust'));
      expect(held, contains('receipts.create'));
      expect(held, isNot(contains('items.delete')));
      expect(held, isNot(contains('items.update')));
      expect(held, isNot(contains('users.view')));
    });
  });

  group('the backend enforces it, whatever the client believes', () {
    test('staff are refused the user list', () async {
      final staff = await server.signedInUser(email: 'staff@example.com');
      final response = await server.get(
        '/users',
        accessToken: staff.accessToken,
      );

      expect(response.statusCode, 403);
      expect(response.errorCode, 'forbidden');
    });

    test('a manager is refused the user list and the audit trail', () async {
      final manager = await server.signedInUser(
        email: 'manager@example.com',
        role: inventoryManagerRoleKey,
      );

      expect(
        (await server.get(
          '/users',
          accessToken: manager.accessToken,
        )).statusCode,
        403,
      );
      expect(
        (await server.get(
          '/audit-logs',
          accessToken: manager.accessToken,
        )).statusCode,
        403,
      );
    });

    test('an administrator is allowed both', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );

      expect(
        (await server.get('/users', accessToken: admin.accessToken)).statusCode,
        200,
      );
      expect(
        (await server.get(
          '/audit-logs',
          accessToken: admin.accessToken,
        )).statusCode,
        200,
      );
    });

    test('an anonymous caller reaches nothing protected', () async {
      for (final path in ['/users', '/audit-logs', '/account/sessions']) {
        final response = await server.get(path);
        expect(response.statusCode, 401, reason: '$path should need a session');
      }
    });

    test('permission is checked per route, not per role', () async {
      // Staff plus exactly one granted permission reaches the endpoint that
      // needs it, and still nothing else — which is the point of §7.
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final staff = await server.createUser(email: 'staff@example.com');

      await server.patch(
        '/users/${staff.id}/permissions',
        body: {
          'permissions': {'users.view': true},
        },
        accessToken: admin.accessToken,
      );

      final session = await server.signIn(staff);
      expect(
        (await server.get(
          '/users',
          accessToken: session.accessToken,
        )).statusCode,
        200,
      );
      // Viewing is not creating.
      final invite = await server.post(
        '/users',
        body: {'email': 'new@example.com', 'name': 'New', 'roles': []},
        accessToken: session.accessToken,
      );
      expect(invite.statusCode, 403);
    });
  });

  group('per-user overrides', () {
    test('an explicit denial beats a role grant', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final manager = await server.createUser(
        email: 'manager@example.com',
        role: inventoryManagerRoleKey,
      );

      await server.patch(
        '/users/${manager.id}/permissions',
        body: {
          'permissions': {'items.delete': false},
        },
        accessToken: admin.accessToken,
      );

      final session = await server.signIn(manager);
      final held =
          ((await server.get(
                    '/auth/session/me',
                    accessToken: session.accessToken,
                  )).user['permissions']!
                  as List)
              .cast<String>();

      // Withheld from this one person without forking the role.
      expect(held, isNot(contains('items.delete')));
      expect(held, contains('items.create'));
    });

    test('an unknown permission key is rejected', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final staff = await server.createUser(email: 'staff@example.com');

      final response = await server.patch(
        '/users/${staff.id}/permissions',
        body: {
          'permissions': {'inventory.teleport': true},
        },
        accessToken: admin.accessToken,
      );
      expect(response.statusCode, 400);
    });
  });

  group('role changes take effect', () {
    test('a promotion grants access on the next sign-in', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final staff = await server.createUser(email: 'staff@example.com');

      final before = await server.signIn(staff);
      expect(
        (await server.get(
          '/users',
          accessToken: before.accessToken,
        )).statusCode,
        403,
      );

      await server.patch(
        '/users/${staff.id}/roles',
        body: {
          'roles': [administratorRoleKey],
        },
        accessToken: admin.accessToken,
      );

      // Permissions are resolved per request, so even the existing token now
      // carries the new access.
      expect(
        (await server.get(
          '/users',
          accessToken: before.accessToken,
        )).statusCode,
        200,
      );
    });

    test('the last administrator cannot demote themselves', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      final me = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );

      final response = await server.patch(
        '/users/${me.user['id']}/roles',
        body: {
          'roles': [staffRoleKey],
        },
        accessToken: admin.accessToken,
      );

      expect(response.statusCode, 409);
      expect(response.errorCode, 'last_administrator');
    });

    test('demotion is allowed once another administrator exists', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: administratorRoleKey,
      );
      await server.createUser(
        email: 'second@example.com',
        role: administratorRoleKey,
      );
      final me = await server.get(
        '/auth/session/me',
        accessToken: admin.accessToken,
      );

      final response = await server.patch(
        '/users/${me.user['id']}/roles',
        body: {
          'roles': [staffRoleKey],
        },
        accessToken: admin.accessToken,
      );
      expect(response.statusCode, 200);
    });
  });
}
