import 'package:stockpile_server/src/auth/token_store.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() async => server.close());

  group('profile', () {
    test('a user can edit their own name and phone', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      final response = await server.patch(
        '/account/profile',
        body: {'name': 'Ada Lovelace', 'phone': '+234 800 000 0000'},
        accessToken: session.accessToken,
      );

      expect(response.statusCode, 200);
      expect(response.user['name'], 'Ada Lovelace');
      expect(response.user['phone'], '+234 800 000 0000');
    });

    test('editing the profile cannot change the role', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      await server.patch(
        '/account/profile',
        body: {
          'name': 'Ada',
          'roles': [administratorRoleKey],
          'status': 'active',
        },
        accessToken: session.accessToken,
      );

      final me = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      // The extra fields are simply not read by the handler.
      expect(me.user['roles'], [staffRoleKey]);
    });
  });

  group('changing the email address', () {
    test('needs the current password', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      final response = await server.post(
        '/account/email',
        body: {'email': 'new@example.com', 'currentPassword': 'wrong'},
        accessToken: session.accessToken,
      );
      expect(response.statusCode, 422);
      expect(response.errorCode, 'wrong_current_password');
    });

    test('does not take effect until the new address is confirmed', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      final started = await server.post(
        '/account/email',
        body: {'email': 'new@example.com', 'currentPassword': user.password},
        accessToken: session.accessToken,
      );
      expect(started.statusCode, 200);

      // Still the old address until the link is followed.
      final me = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(me.user['email'], 'ada@example.com');

      // The confirmation goes to the new mailbox.
      expect(server.mailer.lastTo('new@example.com'), isNotNull);

      final token = server.tokenFromMailTo('new@example.com');
      final confirmed = await server.post(
        '/account/public/verify-email-change',
        body: {'token': token},
      );
      expect(confirmed.statusCode, 200);

      final after = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(after.user['email'], 'new@example.com');
    });

    test('warns the old address after the change', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);
      await server.post(
        '/account/email',
        body: {'email': 'new@example.com', 'currentPassword': user.password},
        accessToken: session.accessToken,
      );
      // Read the link before emptying the mailbox, so what follows can only
      // have been sent by the confirmation itself.
      final token = server.tokenFromMailTo('new@example.com');
      server.mailer.clear();

      final confirmed = await server.post(
        '/account/public/verify-email-change',
        body: {'token': token},
      );
      expect(confirmed.statusCode, 200);

      final warning = server.mailer.lastTo('ada@example.com');
      expect(warning, isNotNull);
      expect(warning!.subject, contains('email address'));
      expect(warning.text, contains('new@example.com'));
    });

    test('refuses an address someone else already has', () async {
      await server.createUser(email: 'taken@example.com');
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      final response = await server.post(
        '/account/email',
        body: {'email': 'taken@example.com', 'currentPassword': user.password},
        accessToken: session.accessToken,
      );
      expect(response.errorCode, 'email_in_use');
    });
  });

  group('sessions and devices', () {
    test('lists them and marks the current one', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.signIn(user);
      final current = await server.signIn(user);

      final response = await server.get(
        '/account/sessions',
        accessToken: current.accessToken,
      );

      final sessions = (response.body['sessions']! as List).cast<Map>();
      expect(sessions, hasLength(2));
      expect(sessions.where((s) => s['isCurrent'] == true), hasLength(1));
      // Device and last-active are shown; no token material is.
      expect(sessions.first.keys, contains('device'));
      expect(sessions.first.keys, contains('lastUsedAt'));
      expect(response.toString(), isNot(contains('TokenHash')));
    });

    test('revoking one signs that device out and no other', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final phone = await server.signIn(user);
      final laptop = await server.signIn(user);

      final listed = await server.get(
        '/account/sessions',
        accessToken: laptop.accessToken,
      );
      final other = (listed.body['sessions']! as List).cast<Map>().firstWhere(
        (s) => s['isCurrent'] == false,
      );

      final revoked = await server.delete(
        '/account/sessions/${other['id']}',
        accessToken: laptop.accessToken,
      );
      expect(revoked.statusCode, 200);

      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: phone.accessToken,
        )).statusCode,
        401,
      );
      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: laptop.accessToken,
        )).statusCode,
        200,
      );
    });

    test("cannot revoke someone else's session", () async {
      final ada = await server.createUser(email: 'ada@example.com');
      final adaSession = await server.signIn(ada);
      final bob = await server.createUser(email: 'bob@example.com');
      final bobSession = await server.signIn(bob);

      final bobSessions = await server.get(
        '/account/sessions',
        accessToken: bobSession.accessToken,
      );
      final bobSessionId =
          ((bobSessions.body['sessions']! as List).first as Map)['id'];

      final response = await server.delete(
        '/account/sessions/$bobSessionId',
        accessToken: adaSession.accessToken,
      );
      // Reported as absent, not forbidden, so ids cannot be probed.
      expect(response.statusCode, 404);

      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: bobSession.accessToken,
        )).statusCode,
        200,
      );
    });
  });

  group('security activity', () {
    test('shows recent successes and failures', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': 'wrong-password-here'},
      );
      final session = await server.signIn(user);

      final response = await server.get(
        '/account/activity',
        accessToken: session.accessToken,
      );

      final activity = (response.body['activity']! as List).cast<Map>();
      expect(activity, hasLength(2));
      expect(activity.where((a) => a['succeeded'] == true), hasLength(1));
      expect(activity.where((a) => a['succeeded'] == false), hasLength(1));
      expect(activity.first.keys, containsAll(['device', 'ipAddress', 'at']));
    });
  });

  group('notification preferences', () {
    test('lists the switchable channels and their defaults', () async {
      final session = await server.signedInUser(email: 'ada@example.com');
      final response = await server.get(
        '/account/notifications',
        accessToken: session.accessToken,
      );

      final channels = (response.body['channels']! as List).cast<Map>();
      final keys = channels.map((c) => c['key']).toList();
      expect(keys, contains('low_stock'));
      // Security mail is not listed, so there is nothing to switch off.
      expect(keys, isNot(contains('password_changed')));
      expect(keys, isNot(contains('new_login')));

      final preferences = response.body['preferences']! as Map;
      expect(preferences['low_stock'], true);
    });

    test('an application notification can be switched off', () async {
      final session = await server.signedInUser(email: 'ada@example.com');

      final response = await server.patch(
        '/account/notifications',
        body: {'low_stock': false},
        accessToken: session.accessToken,
      );
      expect((response.body['preferences']! as Map)['low_stock'], false);

      final reread = await server.get(
        '/account/notifications',
        accessToken: session.accessToken,
      );
      expect((reread.body['preferences']! as Map)['low_stock'], false);
    });

    test('a security notification cannot be switched off', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      // The attempt is accepted but has no effect: there is no such channel.
      final response = await server.patch(
        '/account/notifications',
        body: {'password_changed': false, 'new_login': false},
        accessToken: session.accessToken,
      );
      expect(response.body['preferences'], isNot(contains('password_changed')));

      server.mailer.clear();
      await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': user.password,
          'newPassword': 'a whole new passphrase',
        },
        accessToken: session.accessToken,
      );

      // The notice arrives regardless.
      expect(server.mailer.lastTo('ada@example.com'), isNotNull);
    });
  });

  group('email verification', () {
    test('an unverified user can request a link and use it', () async {
      final user = await server.createUser(
        email: 'ada@example.com',
        emailVerified: false,
      );

      final blocked = await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': user.password},
      );
      expect(blocked.errorCode, 'email_unverified');

      await server.post(
        '/auth/resend-verification',
        body: {'email': user.email},
      );
      final token = server.tokenFromMailTo(user.email);
      expect(token, isNotNull);

      final verified = await server.post(
        '/auth/verify-email',
        body: {'token': token},
      );
      expect(verified.statusCode, 200);

      final signIn = await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': user.password},
      );
      expect(signIn.statusCode, 200);
      expect(signIn.user['emailVerified'], true);
    });

    test('a verification link is single-use', () async {
      final user = await server.createUser(
        email: 'ada@example.com',
        emailVerified: false,
      );
      await server.post(
        '/auth/resend-verification',
        body: {'email': user.email},
      );
      final token = server.tokenFromMailTo(user.email);

      await server.post('/auth/verify-email', body: {'token': token});
      final second = await server.post(
        '/auth/verify-email',
        body: {'token': token},
      );
      expect(second.errorCode, 'token_used');
    });

    test('an expired verification link is refused', () async {
      final user = await server.createUser(
        email: 'ada@example.com',
        emailVerified: false,
      );
      await server.post(
        '/auth/resend-verification',
        body: {'email': user.email},
      );
      final token = server.tokenFromMailTo(user.email);
      await server.expireTokensFor(user.id, TokenPurpose.emailVerification);

      final response = await server.post(
        '/auth/verify-email',
        body: {'token': token},
      );
      expect(response.errorCode, 'token_expired');
    });

    test('resending is capped, and says nothing either way', () async {
      final user = await server.createUser(
        email: 'ada@example.com',
        emailVerified: false,
      );

      for (var attempt = 0; attempt < 5; attempt++) {
        final response = await server.post(
          '/auth/resend-verification',
          body: {'email': user.email},
        );
        // Always the same generic answer, whether or not mail was sent.
        expect(response.statusCode, 200);
      }
      // The cap is three per fifteen minutes.
      expect(server.mailer.sent.length, lessThanOrEqualTo(3));
    });

    test('resending for an unknown address reveals nothing', () async {
      final known = await server.post(
        '/auth/resend-verification',
        body: {'email': 'nobody@example.com'},
      );
      expect(known.statusCode, 200);
      expect(server.mailer.sent, isEmpty);
    });
  });
}
