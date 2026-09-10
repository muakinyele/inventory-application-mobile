import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Argon2id parameters, from the OWASP Password Storage Cheat Sheet's
/// second-choice configuration: 19 MiB of memory, two passes, one lane.
///
/// Memory-hardness is the point — it is what makes a GPU farm no better at
/// this than a CPU. These are recorded *in every hash* (see the PHC string
/// below), so raising them later re-hashes users on their next sign-in
/// instead of invalidating every existing password.
const int defaultMemoryKib = 19 * 1024;
const int defaultIterations = 2;
const int defaultParallelism = 1;
const int _hashLength = 32;
const int _saltLength = 16;

/// Long enough to be meaningful, short enough not to be a chore (§11).
const int minPasswordLength = 10;

/// Argon2 will happily hash a 10 MB string and take the server down with it,
/// so the input is capped well above any real password.
const int maxPasswordLength = 200;

final _random = Random.secure();

/// Hashes and verifies passwords.
///
/// Kept behind a class so tests can substitute cheaper parameters; the real
/// cost is deliberate and would make a 200-case test suite take minutes.
class PasswordHasher {
  PasswordHasher({
    int memoryKib = defaultMemoryKib,
    int iterations = defaultIterations,
    int parallelism = defaultParallelism,
  }) : _algorithm = Argon2id(
         memory: memoryKib,
         iterations: iterations,
         parallelism: parallelism,
         hashLength: _hashLength,
       ),
       _memoryKib = memoryKib,
       _iterations = iterations,
       _parallelism = parallelism;

  final Argon2id _algorithm;
  final int _memoryKib;
  final int _iterations;
  final int _parallelism;

  /// Returns a PHC-format string carrying the parameters and salt alongside
  /// the digest, so verification never has to guess how a hash was made.
  Future<String> hash(String password) async {
    final salt = Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => _random.nextInt(256)),
    );
    final key = await _algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return '\$argon2id\$v=19\$m=$_memoryKib,t=$_iterations,p=$_parallelism'
        '\$${_b64(salt)}\$${_b64(bytes)}';
  }

  /// Verifies [password] against [encoded], using the parameters recorded in
  /// [encoded] rather than the current defaults.
  ///
  /// Returns false rather than throwing on a malformed hash: a corrupt row
  /// must not become an exception on the login path, where the difference
  /// between "error" and "wrong password" is itself an oracle.
  Future<bool> verify(String password, String encoded) async {
    final parsed = _ParsedHash.tryParse(encoded);
    if (parsed == null) return false;
    if (password.length > maxPasswordLength) return false;

    final algorithm = Argon2id(
      memory: parsed.memoryKib,
      iterations: parsed.iterations,
      parallelism: parsed.parallelism,
      hashLength: parsed.digest.length,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: parsed.salt,
    );
    return _constantTimeEquals(await key.extractBytes(), parsed.digest);
  }

  /// True when [encoded] was made with weaker parameters than the current
  /// defaults, so the caller can transparently upgrade it after a successful
  /// sign-in — the one moment the plaintext is legitimately in hand.
  bool needsRehash(String encoded) {
    final parsed = _ParsedHash.tryParse(encoded);
    if (parsed == null) return true;
    return parsed.memoryKib < _memoryKib ||
        parsed.iterations < _iterations ||
        parsed.parallelism != _parallelism;
  }

  static String _b64(List<int> bytes) =>
      base64.encode(bytes).replaceAll('=', '');
}

class _ParsedHash {
  _ParsedHash({
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.salt,
    required this.digest,
  });

  final int memoryKib;
  final int iterations;
  final int parallelism;
  final Uint8List salt;
  final Uint8List digest;

  static _ParsedHash? tryParse(String encoded) {
    // $argon2id$v=19$m=19456,t=2,p=1$<salt>$<digest>
    final parts = encoded.split(r'$');
    if (parts.length != 6) return null;
    if (parts[1] != 'argon2id') return null;

    final params = <String, int>{};
    for (final pair in parts[3].split(',')) {
      final kv = pair.split('=');
      if (kv.length != 2) return null;
      final value = int.tryParse(kv[1]);
      if (value == null) return null;
      params[kv[0]] = value;
    }
    final memory = params['m'];
    final iterations = params['t'];
    final parallelism = params['p'];
    if (memory == null || iterations == null || parallelism == null) {
      return null;
    }

    try {
      return _ParsedHash(
        memoryKib: memory,
        iterations: iterations,
        parallelism: parallelism,
        salt: _unb64(parts[4]),
        digest: _unb64(parts[5]),
      );
    } on FormatException {
      return null;
    }
  }

  static Uint8List _unb64(String value) {
    final padded = value.padRight((value.length + 3) & ~3, '=');
    return Uint8List.fromList(base64.decode(padded));
  }
}

/// Compares without an early exit, so timing cannot reveal how many leading
/// bytes were right.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
