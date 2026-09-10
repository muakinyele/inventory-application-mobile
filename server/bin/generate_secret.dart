import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Prints a value suitable for `TOKEN_PEPPER`.
///
/// 32 bytes of `Random.secure` entropy, base64url-encoded. Run it once per
/// environment and store the result with your other secrets — changing it
/// invalidates every session and every outstanding reset link, which is
/// occasionally useful and usually not what you want.
void main() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  stdout.writeln(base64Url.encode(bytes).replaceAll('=', ''));
}
