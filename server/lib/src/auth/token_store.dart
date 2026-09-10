import 'package:drift/drift.dart';

import '../db/database.dart';
import 'tokens.dart';

/// The four kinds of one-time link the system issues.
abstract final class TokenPurpose {
  static const invitation = 'invitation';
  static const passwordReset = 'password_reset';
  static const emailVerification = 'email_verification';
  static const emailChange = 'email_change';
}

/// Why a presented one-time token could not be used.
enum TokenRejection { unknown, expired, alreadyUsed }

/// Issues and redeems single-use, time-limited tokens (§9, §10, §12).
///
/// All four purposes share this one implementation deliberately: they have
/// identical security requirements — cryptographically random, stored only as
/// a hash, single-use, expiring — and one implementation is one place to get
/// that right rather than four places to get it subtly different.
class TokenStore {
  TokenStore({required this.db, required this.tokens});

  final AuthDatabase db;
  final TokenService tokens;

  /// Mints a token and returns the plaintext, which is never stored.
  ///
  /// Any outstanding token of the same purpose for the same user is consumed
  /// first, so requesting a second reset link silently invalidates the first.
  /// Without that, every "resend" would widen the window of live tokens.
  Future<String> issue({
    required String userId,
    required String purpose,
    required Duration validFor,
    String? payload,
    String? createdBy,
  }) async {
    await invalidateOutstanding(userId: userId, purpose: purpose);

    final token = tokens.mint();
    final now = DateTime.now().toUtc();
    await db
        .into(db.authTokens)
        .insert(
          AuthTokensCompanion.insert(
            id: newId(),
            userId: userId,
            purpose: purpose,
            tokenHash: tokens.fingerprint(token),
            expiresAt: now.add(validFor),
            payload: Value(payload),
            createdBy: Value(createdBy),
            createdAt: now,
          ),
        );
    return token;
  }

  /// Redeems [token], marking it used in the same step.
  ///
  /// The consume is a conditional update on `consumed_at IS NULL`, so two
  /// requests racing with the same link cannot both succeed — the second sees
  /// zero rows updated and is rejected as already used.
  Future<({AuthToken? token, TokenRejection? rejection})> consume({
    required String token,
    required String purpose,
  }) async {
    final row =
        await (db.select(db.authTokens)
              ..where((t) => t.tokenHash.equals(tokens.fingerprint(token)))
              ..where((t) => t.purpose.equals(purpose)))
            .getSingleOrNull();

    if (row == null) {
      return (token: null, rejection: TokenRejection.unknown);
    }
    if (row.consumedAt != null) {
      return (token: null, rejection: TokenRejection.alreadyUsed);
    }
    if (row.expiresAt.isBefore(DateTime.now().toUtc())) {
      return (token: null, rejection: TokenRejection.expired);
    }

    final updated =
        await (db.update(db.authTokens)
              ..where((t) => t.id.equals(row.id))
              ..where((t) => t.consumedAt.isNull()))
            .write(
              AuthTokensCompanion(consumedAt: Value(DateTime.now().toUtc())),
            );
    if (updated == 0) {
      return (token: null, rejection: TokenRejection.alreadyUsed);
    }
    return (token: row, rejection: null);
  }

  /// Looks a token up without redeeming it, so a page can tell the user their
  /// link has expired before asking them to type a new password.
  Future<({AuthToken? token, TokenRejection? rejection})> peek({
    required String token,
    required String purpose,
  }) async {
    final row =
        await (db.select(db.authTokens)
              ..where((t) => t.tokenHash.equals(tokens.fingerprint(token)))
              ..where((t) => t.purpose.equals(purpose)))
            .getSingleOrNull();
    if (row == null) return (token: null, rejection: TokenRejection.unknown);
    if (row.consumedAt != null) {
      return (token: null, rejection: TokenRejection.alreadyUsed);
    }
    if (row.expiresAt.isBefore(DateTime.now().toUtc())) {
      return (token: null, rejection: TokenRejection.expired);
    }
    return (token: row, rejection: null);
  }

  Future<int> invalidateOutstanding({
    required String userId,
    required String purpose,
  }) {
    return (db.update(db.authTokens)
          ..where((t) => t.userId.equals(userId))
          ..where((t) => t.purpose.equals(purpose))
          ..where((t) => t.consumedAt.isNull()))
        .write(AuthTokensCompanion(consumedAt: Value(DateTime.now().toUtc())));
  }

  /// How many of this purpose were issued for a user recently, so the resend
  /// endpoints can refuse to be used as a mail cannon (§12).
  Future<int> issuedSince({
    required String userId,
    required String purpose,
    required Duration window,
  }) async {
    final since = DateTime.now().toUtc().subtract(window);
    final count = db.authTokens.id.count();
    final query = db.selectOnly(db.authTokens)
      ..addColumns([count])
      ..where(db.authTokens.userId.equals(userId))
      ..where(db.authTokens.purpose.equals(purpose))
      ..where(db.authTokens.createdAt.isBiggerThanValue(since));
    return (await query.getSingle()).read(count) ?? 0;
  }

  /// Removes tokens that expired a while ago.
  Future<int> purgeExpired({Duration keepFor = const Duration(days: 7)}) {
    final cutoff = DateTime.now().toUtc().subtract(keepFor);
    return (db.delete(
      db.authTokens,
    )..where((t) => t.expiresAt.isSmallerThanValue(cutoff))).go();
  }
}
