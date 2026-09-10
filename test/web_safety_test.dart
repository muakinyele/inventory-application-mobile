@TestOn('browser')
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/ids.dart';

import 'auth_support.dart';

/// These run in a real browser (`flutter test --platform chrome`), where Dart
/// ints are JavaScript doubles and bitwise operations are 32-bit. A generator
/// bounded by `1 << 32` passes on the 64-bit VM and throws here — which is
/// exactly how the add/delete regression escaped the rest of the suite.
void main() {
  test('a 32-bit shift really does wrap to zero on the web', () {
    // Documents the hazard this guard exists for.
    expect(1 << 32, 0);
    expect(() => Random().nextInt(1 << 32), throwsRangeError);
  });

  test('the id bound stays inside what nextInt accepts on the web', () {
    expect(IdGenerator.maxRandomBound, greaterThan(0));
    expect(() => Random().nextInt(IdGenerator.maxRandomBound), returnsNormally);
  });

  test('generating ids does not throw in the browser', () {
    final ids = IdGenerator();
    expect(ids.next, returnsNormally);
    expect(ids.next(), isNotEmpty);
  });

  test('ids stay unique when generated back to back', () {
    final ids = IdGenerator();
    expect({for (var i = 0; i < 500; i++) ids.next()}, hasLength(500));
  });

  test('the API client sets no header a browser refuses to send', () async {
    // `User-Agent` is a *forbidden header name* in a browser: assigning it
    // from JS makes the request fail outright rather than dropping the
    // header. Setting it unconditionally silently broke sign-in on the web
    // build — every call came back as "could not reach the server" — so this
    // asserts the client leaves it to the browser.
    const forbidden = {
      'user-agent',
      'host',
      'origin',
      'referer',
      'cookie',
      'connection',
      'content-length',
      'accept-encoding',
    };

    final server = FakeAuthServer();
    final (:auth, storage: _) = newAuth(server);
    await auth.signIn(
      email: 'ada@example.com',
      password: 'correct-horse-battery',
      rememberMe: true,
    );
    await auth.api.me();

    expect(server.sentHeaders, isNotEmpty);
    for (final headers in server.sentHeaders) {
      for (final name in headers.keys) {
        expect(
          forbidden,
          isNot(contains(name.toLowerCase())),
          reason: 'a browser will not send a request that sets "$name"',
        );
      }
    }
  });
}
