import 'package:stockpile_server/src/audit/audit_actions.dart';
import 'package:stockpile_server/src/auth/password_policy.dart';
import 'package:stockpile_server/src/auth/passwords.dart';
import 'package:stockpile_server/src/auth/token_store.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('hashing', () {
    // Real parameters here: the point is that the algorithm behaves, and this
    // is the one place worth paying for it.
    final hasher = PasswordHasher(memoryKib: 512, iterations: 1);

    test('a hash verifies and is salted per password', () async {
      final first = await hasher.hash('correct-horse-battery');
      final second = await hasher.hash('correct-horse-battery');

      expect(first, isNot(second), reason: 'each hash needs its own salt');
      expect(await hasher.verify('correct-horse-battery', first), isTrue);
      expect(await hasher.verify('correct-horse-battery', second), isTrue);
      expect(await hasher.verify('wrong-password-here', first), isFalse);
    });

    test(
      'the stored form is PHC-encoded argon2id with its parameters',
      () async {
        final hash = await hasher.hash('correct-horse-battery');
        expect(hash, startsWith(r'$argon2id$v=19$'));
        expect(hash, contains('m=512,t=1,p=1'));
        // The plaintext never appears in what is stored.
        expect(hash, isNot(contains('correct-horse-battery')));
      },
    );

    test(
      'a malformed hash is a failed verification, never an exception',
      () async {
        expect(await hasher.verify('anything', 'not-a-hash'), isFalse);
        expect(await hasher.verify('anything', r'$argon2id$broken'), isFalse);
        expect(await hasher.verify('anything', ''), isFalse);
      },
    );

    test('needsRehash spots a hash made with weaker parameters', () async {
      final weak = await PasswordHasher(
        memoryKib: 256,
        iterations: 1,
      ).hash('correct-horse-battery');
      final strong = PasswordHasher(memoryKib: 1024, iterations: 2);

      expect(strong.needsRehash(weak), isTrue);
      expect(strong.needsRehash(await strong.hash('x')), isFalse);
    });
  });

  group('policy', () {
    const policy = PasswordPolicy();

    test('accepts a reasonable passphrase without composition rules', () {
      final result = policy.check('the quiet warehouse');
      expect(result.isAcceptable, isTrue);
      expect(result.strength, greaterThanOrEqualTo(2));
    });

    test('rejects one that is too short', () {
      final result = policy.check('short1');
      expect(result.isAcceptable, isFalse);
      expect(result.problems.first, contains('at least'));
    });

    test('rejects common passwords', () {
      expect(policy.check('password123').isAcceptable, isFalse);
      expect(policy.check('qwertyuiop').isAcceptable, isFalse);
      expect(policy.check('letmein123').isAcceptable, isFalse);
    });

    test('rejects sequences and repetition', () {
      expect(policy.check('abcdefghijkl').isAcceptable, isFalse);
      expect(policy.check('aaaaaaaaaaaa').isAcceptable, isFalse);
    });

    test('rejects a password derived from the account', () {
      final result = policy.check(
        'ada-lovelace-99',
        email: 'ada-lovelace@example.com',
      );
      expect(result.isAcceptable, isFalse);
      expect(result.problems.first, contains('your name'));
    });

    test('a long passphrase scores well; a bare minimum scores low', () {
      expect(policy.check('correct horse battery staple').strength, 4);
      expect(policy.check('abcdefghij1').strength, lessThan(3));
    });
  });

  group('change password', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() async => server.close());

    test('changes it, keeps this device signed in, drops the others', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final phone = await server.signIn(user);
      final laptop = await server.signIn(user);

      final response = await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': user.password,
          'newPassword': 'a whole new passphrase',
        },
        accessToken: laptop.accessToken,
      );
      expect(response.statusCode, 200);

      // The response carries a fresh pair, so the user is not bounced to the
      // sign-in screen for doing the right thing.
      final replacement = response.accessToken;
      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: replacement,
        )).statusCode,
        200,
      );

      // Every other device is gone.
      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: phone.accessToken,
        )).statusCode,
        401,
      );
      // Including the token that made the change.
      expect(
        (await server.get(
          '/auth/session/me',
          accessToken: laptop.accessToken,
        )).statusCode,
        401,
      );
    });

    test('the new password works and the old one does not', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': user.password,
          'newPassword': 'a whole new passphrase',
        },
        accessToken: session.accessToken,
      );

      final withOld = await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': user.password},
      );
      expect(withOld.statusCode, 401);

      final withNew = await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': 'a whole new passphrase'},
      );
      expect(withNew.statusCode, 200);
    });

    test('refuses a wrong current password', () async {
      final session = await server.signedInUser(email: 'ada@example.com');
      final response = await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': 'not-the-right-one',
          'newPassword': 'a whole new passphrase',
        },
        accessToken: session.accessToken,
      );

      expect(response.statusCode, 422);
      expect(response.errorCode, 'wrong_current_password');
    });

    test('refuses a weak new password and says why', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      final response = await server.post(
        '/auth/session/change-password',
        body: {'currentPassword': user.password, 'newPassword': 'password123'},
        accessToken: session.accessToken,
      );

      expect(response.statusCode, 422);
      expect(response.errorCode, 'weak_password');
      expect(
        (response.body['error']! as Map)['details'],
        isA<List<Object?>>().having((d) => d.length, 'problems', isPositive),
      );
    });

    test('emails the user that it changed', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);
      server.mailer.clear();

      await server.post(
        '/auth/session/change-password',
        body: {
          'currentPassword': user.password,
          'newPassword': 'a whole new passphrase',
        },
        accessToken: session.accessToken,
      );

      final mail = server.mailer.lastTo('ada@example.com');
      expect(mail, isNotNull);
      expect(mail!.subject, contains('password was changed'));
      // The notice must not carry either password.
      expect(mail.text, isNot(contains('a whole new passphrase')));
      expect(mail.text, isNot(contains(user.password)));
    });
  });

  group('forgot and reset password', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() async => server.close());

    test('answers identically whether or not the account exists', () async {
      await server.createUser(email: 'ada@example.com');

      final known = await server.post(
        '/auth/forgot-password',
        body: {'email': 'ada@example.com'},
      );
      final unknown = await server.post(
        '/auth/forgot-password',
        body: {'email': 'nobody@example.com'},
      );

      expect(known.statusCode, 200);
      expect(unknown.statusCode, 200);
      expect(known.body['message'], unknown.body['message']);
      expect(
        known.body['message'],
        'If an account exists for this email address, password reset '
        'instructions have been sent.',
      );

      // Only the real address was actually written to.
      expect(server.mailer.lastTo('ada@example.com'), isNotNull);
      expect(server.mailer.lastTo('nobody@example.com'), isNull);
    });

    test('a reset link sets a new password once', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post('/auth/forgot-password', body: {'email': user.email});
      final token = server.tokenFromMailTo(user.email);
      expect(token, isNotNull);

      final reset = await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'a whole new passphrase'},
      );
      expect(reset.statusCode, 200);

      final signIn = await server.post(
        '/auth/login',
        body: {'email': user.email, 'password': 'a whole new passphrase'},
      );
      expect(signIn.statusCode, 200);
    });

    test('the same link cannot be used twice', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post('/auth/forgot-password', body: {'email': user.email});
      final token = server.tokenFromMailTo(user.email);

      await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'a whole new passphrase'},
      );
      final second = await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'yet another passphrase'},
      );

      expect(second.statusCode, 400);
      expect(second.errorCode, 'token_used');
      expect(second.errorMessage, contains('already been used'));
    });

    test('an expired link is refused with its own message', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post('/auth/forgot-password', body: {'email': user.email});
      final token = server.tokenFromMailTo(user.email);

      await server.expireTokensFor(user.id, TokenPurpose.passwordReset);

      final response = await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'a whole new passphrase'},
      );
      expect(response.statusCode, 400);
      expect(response.errorCode, 'token_expired');
      expect(response.errorMessage, contains('expired'));
    });

    test('a made-up token is refused', () async {
      final response = await server.post(
        '/auth/reset-password',
        body: {'token': 'completely-invented', 'password': 'a new passphrase'},
      );
      expect(response.errorCode, 'token_invalid');
    });

    test('a rejected password does not burn the link', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post('/auth/forgot-password', body: {'email': user.email});
      final token = server.tokenFromMailTo(user.email);

      final weak = await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'password123'},
      );
      expect(weak.errorCode, 'weak_password');

      // The user gets to try again with the link they already have.
      final good = await server.post(
        '/auth/reset-password',
        body: {'token': token, 'password': 'a whole new passphrase'},
      );
      expect(good.statusCode, 200);
    });

    test('requesting a second link invalidates the first', () async {
      final user = await server.createUser(email: 'ada@example.com');

      await server.post('/auth/forgot-password', body: {'email': user.email});
      final first = server.tokenFromMailTo(user.email);
      server.mailer.clear();

      await server.post('/auth/forgot-password', body: {'email': user.email});
      final second = server.tokenFromMailTo(user.email);
      expect(second, isNot(first));

      final withOld = await server.post(
        '/auth/reset-password',
        body: {'token': first, 'password': 'a whole new passphrase'},
      );
      expect(withOld.errorCode, 'token_used');

      final withNew = await server.post(
        '/auth/reset-password',
        body: {'token': second, 'password': 'a whole new passphrase'},
      );
      expect(withNew.statusCode, 200);
    });

    test('completing a reset signs every device out', () async {
      final user = await server.createUser(email: 'ada@example.com');
      final session = await server.signIn(user);

      await server.post('/auth/forgot-password', body: {'email': user.email});
      await server.post(
        '/auth/reset-password',
        body: {
          'token': server.tokenFromMailTo(user.email),
          'password': 'a whole new passphrase',
        },
      );

      final response = await server.get(
        '/auth/session/me',
        accessToken: session.accessToken,
      );
      expect(response.statusCode, 401);
    });

    test('the reset is recorded in the audit trail', () async {
      final user = await server.createUser(email: 'ada@example.com');
      await server.post('/auth/forgot-password', body: {'email': user.email});
      await server.post(
        '/auth/reset-password',
        body: {
          'token': server.tokenFromMailTo(user.email),
          'password': 'a whole new passphrase',
        },
      );

      expect(
        await server.auditEntries(action: AuditAction.passwordResetRequested),
        hasLength(1),
      );
      expect(
        await server.auditEntries(action: AuditAction.passwordResetCompleted),
        hasLength(1),
      );
    });

    test(
      'an administrator can start a reset without seeing the password',
      () async {
        final admin = await server.signedInUser(
          email: 'admin@example.com',
          role: administratorRoleKey,
        );
        final victim = await server.createUser(email: 'ada@example.com');
        final victimSession = await server.signIn(victim);
        server.mailer.clear();

        final response = await server.post(
          '/users/${victim.id}/reset-password',
          accessToken: admin.accessToken,
        );
        expect(response.statusCode, 200);

        // The link goes to the user, not into the admin's response.
        expect(response.toString(), isNot(contains('token=')));
        expect(server.tokenFromMailTo('ada@example.com'), isNotNull);

        // Their devices are signed out straight away.
        expect(
          (await server.get(
            '/auth/session/me',
            accessToken: victimSession.accessToken,
          )).statusCode,
          401,
        );
      },
    );
  });
}
