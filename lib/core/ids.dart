import 'dart:math';

/// Generates the string ids used for items and movements.
///
/// The random bound is 0x3FFFFFFF rather than `1 << 32`. On the web Dart ints
/// are JavaScript doubles and bitwise shifts are 32-bit, so `1 << 32` wraps to
/// zero and `Random.nextInt(0)` throws — a bug that passes on the 64-bit VM and
/// breaks every mutation in the browser. Keep this bound web-safe.
class IdGenerator {
  IdGenerator([Random? random]) : _random = random ?? Random();

  static const maxRandomBound = 0x3FFFFFFF;

  final Random _random;
  int _sequence = 0;

  /// Timestamp + per-instance counter + randomness, so ids stay unique even
  /// when many are minted inside the same microsecond.
  String next() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = (_sequence++).toRadixString(36);
    final salt = _random.nextInt(maxRandomBound).toRadixString(36);
    return '$stamp-$seq-$salt';
  }
}
