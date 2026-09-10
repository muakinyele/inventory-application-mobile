import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// 256 bits. Well past guessing, and it keeps the emailed links a reasonable
/// length once base64url-encoded.
const int _tokenBytes = 32;

/// Mints and fingerprints the opaque secrets the system hands out — session
/// tokens, invitation links, reset links.
///
/// Everything here is *hashed before storage*. The plaintext exists only in
/// the response body or the email that carried it, so a database disclosure
/// alone never yields a working credential.
class TokenService {
  TokenService(this._pepper);

  /// Mixed into every hash. Kept in the environment rather than the database,
  /// so an attacker with a stolen dump but no server access cannot verify
  /// guesses offline against the stored hashes.
  final String _pepper;

  /// A fresh, URL-safe secret. Unpadded so it survives being pasted out of an
  /// email client that mangles `=`.
  String mint() {
    final bytes = Uint8List.fromList(
      List<int>.generate(_tokenBytes, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// The value stored in the database for [token].
  ///
  /// SHA-256 rather than Argon2 on purpose: these tokens are 256 bits of
  /// uniform randomness, so there is no dictionary to slow down, and the
  /// session lookup happens on every single request.
  String fingerprint(String token) {
    final digest = sha256.convert(utf8.encode('$_pepper:$token'));
    return digest.toString();
  }

  /// Compares a presented token against a stored fingerprint without an early
  /// exit. Matters less than for passwords — the comparison is over a hash of
  /// the input — but it costs nothing to be careful.
  bool matches(String presented, String storedFingerprint) {
    final computed = fingerprint(presented);
    if (computed.length != storedFingerprint.length) return false;
    var difference = 0;
    for (var i = 0; i < computed.length; i++) {
      difference |= computed.codeUnitAt(i) ^ storedFingerprint.codeUnitAt(i);
    }
    return difference == 0;
  }
}

/// A UUIDv4, for primary keys.
///
/// Hand-rolled rather than pulling in a package for eight lines: the version
/// and variant bits are set per RFC 4122, and the source is [Random.secure].
String newId() {
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => _random.nextInt(256)),
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
