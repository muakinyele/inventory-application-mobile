import 'package:shelf/shelf.dart' as shelf;
import 'package:stockpile_server/src/auth/device_label.dart';
import 'package:stockpile_server/src/auth/tokens.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/http/rate_limiter.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('token service', () {
    test('mints unguessable, URL-safe tokens', () {
      final service = TokenService('a-pepper-of-sufficient-length-here');
      final tokens = {for (var i = 0; i < 500; i++) service.mint()};

      expect(tokens, hasLength(500), reason: 'tokens must not repeat');
      for (final token in tokens.take(20)) {
        expect(token, matches(RegExp(r'^[A-Za-z0-9_\-]+$')));
        expect(token.length, greaterThanOrEqualTo(40));
      }
    });

    test('a fingerprint does not reveal its token, and needs the pepper', () {
      final service = TokenService('a-pepper-of-sufficient-length-here');
      final other = TokenService('a-different-pepper-of-good-length!');
      final token = service.mint();

      final fingerprint = service.fingerprint(token);
      expect(fingerprint, isNot(contains(token)));
      expect(service.matches(token, fingerprint), isTrue);

      // The same token under a different pepper does not match — which is why
      // a stolen database alone cannot be used to forge a session.
      expect(other.matches(token, fingerprint), isFalse);
    });

    test('ids are unique UUIDv4', () {
      final ids = {for (var i = 0; i < 500; i++) newId()};
      expect(ids, hasLength(500));
      expect(
        ids.first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  group('device labels', () {
    test('reduce a User-Agent to something a person recognises', () {
      expect(
        describeDevice(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        ),
        'Chrome on macOS',
      );
      expect(
        describeDevice(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        ),
        'Safari on iPhone',
      );
      expect(
        describeDevice('Stockpile/1.0 (Android)'),
        'Stockpile app (Android)',
      );
      expect(describeDevice(null), 'Unknown device');
    });

    test('does not keep the raw header as a fingerprint', () {
      const ua =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) '
          'Gecko/20100101 Firefox/121.0';
      final label = describeDevice(ua);

      expect(label, 'Firefox on Windows');
      expect(label, isNot(contains('rv:109')));
      expect(label.length, lessThan(40));
    });
  });

  group('rate limiter', () {
    test('allows up to the limit then refuses with a retry hint', () {
      final limiter = RateLimiter(limit: 3, window: const Duration(minutes: 1));

      for (var i = 0; i < 3; i++) {
        expect(limiter.hit('key').allowed, isTrue);
      }
      final blocked = limiter.hit('key');
      expect(blocked.allowed, isFalse);
      expect(blocked.retryAfter, isNotNull);
    });

    test('keys are independent, and a reset clears one', () {
      final limiter = RateLimiter(limit: 1, window: const Duration(minutes: 1));

      expect(limiter.hit('a').allowed, isTrue);
      expect(limiter.hit('a').allowed, isFalse);
      expect(limiter.hit('b').allowed, isTrue);

      limiter.reset('a');
      expect(limiter.hit('a').allowed, isTrue);
    });
  });

  group('configuration refuses to be insecure', () {
    Env load(Map<String, String> overrides) => Env.load(
      envFile: '.env.test.absent',
      overrides: {'DATABASE_URL': 'postgres://localhost:5432/x', ...overrides},
    );

    test('production without a pepper will not start', () {
      expect(
        () => load({'APP_ENV': 'production', 'APP_URL': 'https://x.example'}),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('TOKEN_PEPPER'),
          ),
        ),
      );
    });

    test('a short pepper is refused', () {
      expect(
        () => load({'TOKEN_PEPPER': 'too-short'}),
        throwsA(isA<ConfigError>()),
      );
    });

    test('production demands SMTP, so resets cannot silently fail', () {
      expect(
        () => load({
          'APP_ENV': 'production',
          'TOKEN_PEPPER': 'a-pepper-that-is-long-enough-to-pass!!',
          'APP_URL': 'https://secure.example',
        }),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('EMAIL_HOST'),
          ),
        ),
      );
    });

    test(
      'production demands an https APP_URL, since links are built from it',
      () {
        expect(
          // EMAIL_HOST is supplied so this asserts the URL rule and not the
          // one that happens to be checked before it.
          () => load({
            'APP_ENV': 'production',
            'TOKEN_PEPPER': 'a-pepper-that-is-long-enough-to-pass!!',
            'EMAIL_HOST': 'smtp.example.com',
            'APP_URL': 'http://insecure.example',
          }),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains('https'),
            ),
          ),
        );
      },
    );

    test('a fully configured production environment loads', () {
      final env = load({
        'APP_ENV': 'production',
        'TOKEN_PEPPER': 'a-pepper-that-is-long-enough-to-pass!!',
        'EMAIL_HOST': 'smtp.example.com',
        'APP_URL': 'https://secure.example/',
      });

      expect(env.isProduction, isTrue);
      expect(env.emailEnabled, isTrue);
      // The trailing slash is stripped, so built links never double up.
      expect(env.appUrl, 'https://secure.example');
    });

    test('a missing database URL is fatal', () {
      expect(
        () => Env.load(envFile: '.env.test.absent', overrides: {'PORT': '1'}),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('responses', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() async => server.close());

    test('carry hardening headers and are never cached', () async {
      final response = await server.get('/health');

      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(response.headers['x-frame-options'], 'DENY');
      expect(response.headers['cache-control'], 'no-store');
      expect(response.headers['referrer-policy'], 'no-referrer');
      expect(
        response.headers['content-security-policy'],
        contains("default-src 'none'"),
      );
    });

    test('the health check says nothing about the stack', () async {
      final response = await server.get('/health');
      expect(response.body, {'status': 'ok'});
      expect(response.headers.keys, isNot(contains('x-powered-by')));
    });

    test('an unknown route is a clean 404, not a stack trace', () async {
      final response = await server.get('/does/not/exist');
      expect(response.statusCode, 404);
      expect(response.errorCode, 'not_found');
      expect(response.toString(), isNot(contains('package:')));
    });

    test('malformed JSON is a 400, not a 500', () async {
      final response = await server.api.handler(
        await _rawRequest('POST', '/auth/login', '{not json at all'),
      );
      expect(response.statusCode, 400);
    });

    test('an oversized body is refused before it is read', () async {
      final huge = 'x' * (128 * 1024);
      final response = await server.post(
        '/auth/login',
        body: {'email': 'a@b.com', 'password': huge},
      );
      expect(response.statusCode, 413);
    });

    test(
      'a cross-origin request from an unlisted origin gets no CORS grant',
      () async {
        final response = await server.api.handler(
          await _rawRequest(
            'OPTIONS',
            '/auth/login',
            null,
            headers: {'origin': 'https://evil.example'},
          ),
        );
        expect(response.statusCode, 403);
        expect(response.headers['access-control-allow-origin'], isNull);
      },
    );

    test(
      'error responses carry CORS headers too, so a browser can read them',
      () async {
        // The bug this exists for: a handler reports failure by *throwing*,
        // and if the error middleware sits outside the CORS middleware the
        // resulting response never gets `Access-Control-Allow-Origin`. The
        // browser then refuses to read it, and every 401 surfaces in the app
        // as "could not reach the server" rather than "Invalid email or
        // password" — while 200s work perfectly, which is what makes it so
        // easy to miss.
        await server.createUser(email: 'ada@example.com');

        for (final (label, request) in [
          (
            'invalid credentials (401, thrown)',
            await _rawRequest(
              'POST',
              '/auth/login',
              '{"email":"ada@example.com","password":"wrong-password-here"}',
              headers: {'origin': 'http://localhost:8080'},
            ),
          ),
          (
            'unauthenticated (401, thrown)',
            await _rawRequest(
              'GET',
              '/auth/session/me',
              null,
              headers: {'origin': 'http://localhost:8080'},
            ),
          ),
          (
            'bad request (400, thrown)',
            await _rawRequest(
              'POST',
              '/auth/login',
              '{}',
              headers: {'origin': 'http://localhost:8080'},
            ),
          ),
          (
            'not found (404, returned)',
            await _rawRequest(
              'GET',
              '/no/such/route',
              null,
              headers: {'origin': 'http://localhost:8080'},
            ),
          ),
        ]) {
          final response = await server.api.handler(request);
          expect(
            response.statusCode,
            greaterThanOrEqualTo(400),
            reason: '$label should be an error',
          );
          expect(
            response.headers['access-control-allow-origin'],
            'http://localhost:8080',
            reason: '$label must still be readable cross-origin',
          );
          // The hardening headers are on the same side of the error
          // middleware, so they have to survive a throw as well.
          expect(
            response.headers['x-content-type-options'],
            'nosniff',
            reason: '$label should still be hardened',
          );
        }
      },
    );

    test('a successful response carries them as well', () async {
      final response = await server.api.handler(
        await _rawRequest(
          'GET',
          '/health',
          null,
          headers: {'origin': 'http://localhost:8080'},
        ),
      );
      expect(response.statusCode, 200);
      expect(
        response.headers['access-control-allow-origin'],
        'http://localhost:8080',
      );
    });

    test('the configured origin is echoed, never a wildcard', () async {
      final response = await server.api.handler(
        await _rawRequest(
          'OPTIONS',
          '/auth/login',
          null,
          headers: {'origin': 'http://localhost:8080'},
        ),
      );
      expect(
        response.headers['access-control-allow-origin'],
        'http://localhost:8080',
      );
      expect(response.headers['access-control-allow-origin'], isNot('*'));
      expect(response.headers['vary'], contains('Origin'));
    });
  });

  group('throttling in the API', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() async => server.close());

    test('a flood of sign-in attempts is eventually refused', () async {
      await server.createUser(email: 'ada@example.com');

      var throttled = false;
      for (var attempt = 0; attempt < 80; attempt++) {
        final response = await server.post(
          '/auth/login',
          body: {
            'email': 'nobody$attempt@example.com',
            'password': 'wrong-guess-here',
          },
        );
        if (response.errorCode == 'too_many_requests') {
          throttled = true;
          expect(response.statusCode, 429);
          expect(response.headers['retry-after'], isNotNull);
          break;
        }
      }
      expect(throttled, isTrue, reason: 'the flood guard must engage');
    });
  });

  group('protecting the administrator of last resort', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() async => server.close());

    test(
      'the system can never be left with nobody able to administer it',
      () async {
        final admin = await server.signedInUser(
          email: 'admin@example.com',
          role: administratorRoleKey,
        );
        final me = await server.get(
          '/auth/session/me',
          accessToken: admin.accessToken,
        );
        final id = me.user['id'];

        // Every route that could strip the last administrator refuses.
        expect(
          (await server.patch(
            '/users/$id/roles',
            body: {
              'roles': [staffRoleKey],
            },
            accessToken: admin.accessToken,
          )).errorCode,
          'last_administrator',
        );
        expect(
          (await server.patch(
            '/users/$id/status',
            body: {'enabled': false},
            accessToken: admin.accessToken,
          )).errorCode,
          'cannot_target_self',
        );
        expect(
          (await server.delete(
            '/users/$id',
            accessToken: admin.accessToken,
          )).errorCode,
          'cannot_target_self',
        );
      },
    );
  });
}

Future<shelf.Request> _rawRequest(
  String method,
  String path,
  String? body, {
  Map<String, String> headers = const {},
}) async {
  return shelf.Request(
    method,
    Uri.parse('http://localhost:8080$path'),
    headers: {'content-type': 'application/json', ...headers},
    body: body,
  );
}
