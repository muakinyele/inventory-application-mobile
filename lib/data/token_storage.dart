import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The pair the client holds on to between launches.
class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;

  /// Treated as expired slightly early, so a request is not sent with a token
  /// that dies in flight.
  bool get accessExpired => DateTime.now().isAfter(
    accessExpiresAt.subtract(const Duration(seconds: 30)),
  );

  bool get refreshExpired => DateTime.now().isAfter(refreshExpiresAt);

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accessExpiresAt': accessExpiresAt.toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt.toIso8601String(),
  };

  static StoredTokens? fromJson(Map<String, dynamic> json) {
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    final accessExpiry = DateTime.tryParse(
      json['accessExpiresAt'] as String? ?? '',
    );
    final refreshExpiry = DateTime.tryParse(
      json['refreshExpiresAt'] as String? ?? '',
    );
    if (access is! String || refresh is! String) return null;
    if (accessExpiry == null || refreshExpiry == null) return null;

    return StoredTokens(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: accessExpiry,
      refreshExpiresAt: refreshExpiry,
    );
  }
}

/// Where session tokens live between launches.
///
/// **The security trade-off, stated plainly.** On Android the data key is
/// held in the Android Keystore and the value is AES-GCM encrypted; on iOS it
/// is the Keychain. Neither is readable by another app. On the **web** there
/// is no equivalent: the browser
/// gives a page no storage that its own JavaScript cannot read, so any XSS
/// that executes in the app's origin can take the token whatever we do.
///
/// The mitigations that are actually available are applied instead:
///  * The access token lives 15 minutes, so a stolen one has a short life.
///  * The refresh token rotates on every use with replay detection, so a
///    stolen copy is detected the moment the real client next refreshes — and
///    the whole session chain is then killed server-side.
///  * Tokens go in a bearer header, never a cookie, which is what makes CSRF
///    structurally inapplicable rather than something to defend against.
///  * The API sets a strict CSP and `no-store`, and the tokens are cleared on
///    sign-out.
///
/// The alternative — an httpOnly cookie — would defend the token against XSS
/// but reintroduce CSRF and does not work for the Android and iOS builds from
/// the same codebase. For an internal tool served over HTTPS this is the
/// better side of the trade; a deployment facing higher risk should put the
/// web build behind a backend-for-frontend that holds the tokens instead.
abstract class TokenStorage {
  Future<StoredTokens?> read();
  Future<void> write(StoredTokens tokens);
  Future<void> clear();
}

class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // v11's default on Android is already AES-GCM with the data key
            // wrapped by an RSA key held in the Android Keystore, so no
            // options are needed to get the strong path.
            iOptions: IOSOptions(
              // Not synced to iCloud, and unreadable until the device has been
              // unlocked once since boot.
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _key = 'stockpile.session';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredTokens?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return StoredTokens.fromJson(decoded);
    } catch (_) {
      // A corrupt or undecryptable blob means "not signed in", never a crash
      // on launch. The user signs in again and it is overwritten.
      return null;
    }
  }

  @override
  Future<void> write(StoredTokens tokens) async {
    await _storage.write(key: _key, value: jsonEncode(tokens.toJson()));
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Nothing useful to do; the in-memory state is cleared regardless.
    }
  }
}

/// For tests and for the "remember me" opt-out, where tokens are deliberately
/// not persisted past the run.
class InMemoryTokenStorage implements TokenStorage {
  StoredTokens? _tokens;

  @override
  Future<StoredTokens?> read() async => _tokens;

  @override
  Future<void> write(StoredTokens tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = null;
}
