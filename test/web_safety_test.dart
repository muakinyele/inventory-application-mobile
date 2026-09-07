@TestOn('browser')
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/ids.dart';

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
}
