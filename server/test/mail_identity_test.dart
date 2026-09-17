import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/email/mail_identity.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() async => server.close());

  Env envWith(Map<String, String> overrides) => Env.load(
    envFile: '.env.test.absent',
    overrides: {
      'DATABASE_URL': 'postgres://localhost:5432/x',
      'EMAIL_HOST': 'smtp.example.com',
      'EMAIL_USERNAME': 'alerts@example.com',
      'EMAIL_PASSWORD': 'secret',
      ...overrides,
    },
  );

  group('who mail comes from', () {
    test('it carries the workspace name, not the software name', () async {
      // A supplier receiving an invitation should see the company that sent
      // it, not the name of the program it was sent with.
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: 'administrator',
      );
      await server.patch(
        '/inventory/preferences',
        accessToken: admin.accessToken,
        body: {
          'preferences': {'companyName': 'Chedra Olympas'},
        },
      );

      final from = await MailIdentity(
        db: server.db,
        env: envWith({}),
      ).resolve();

      expect(from, 'Chedra Olympas <alerts@example.com>');
    });

    test(
      'a renamed workspace changes the next message, not the next restart',
      () async {
        final admin = await server.signedInUser(
          email: 'admin@example.com',
          role: 'administrator',
        );
        final identity = MailIdentity(db: server.db, env: envWith({}));

        await server.patch(
          '/inventory/preferences',
          accessToken: admin.accessToken,
          body: {
            'preferences': {'companyName': 'First Name'},
          },
        );
        expect(await identity.resolve(), startsWith('First Name <'));

        await server.patch(
          '/inventory/preferences',
          accessToken: admin.accessToken,
          body: {
            'preferences': {'companyName': 'Second Name'},
          },
        );
        expect(await identity.resolve(), startsWith('Second Name <'));
      },
    );

    test('an unnamed workspace falls back to the application name', () async {
      final from = await MailIdentity(
        db: server.db,
        env: envWith({'APP_NAME': 'Stockpile'}),
      ).resolve();

      expect(from, 'Stockpile <alerts@example.com>');
    });

    test('an explicit EMAIL_FROM with a name is left alone', () async {
      // Somebody stating exactly what they want should get it.
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: 'administrator',
      );
      await server.patch(
        '/inventory/preferences',
        accessToken: admin.accessToken,
        body: {
          'preferences': {'companyName': 'Chedra Olympas'},
        },
      );

      final from = await MailIdentity(
        db: server.db,
        env: envWith({'EMAIL_FROM': 'Accounts <billing@example.com>'}),
      ).resolve();

      expect(from, 'Accounts <billing@example.com>');
    });

    test('a bare EMAIL_FROM keeps its address and gains the name', () async {
      final admin = await server.signedInUser(
        email: 'admin@example.com',
        role: 'administrator',
      );
      await server.patch(
        '/inventory/preferences',
        accessToken: admin.accessToken,
        body: {
          'preferences': {'companyName': 'Chedra Olympas'},
        },
      );

      final from = await MailIdentity(
        db: server.db,
        env: envWith({'EMAIL_FROM': 'billing@example.com'}),
      ).resolve();

      expect(from, 'Chedra Olympas <billing@example.com>');
    });
  });
}
