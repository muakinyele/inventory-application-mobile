import 'package:drift/drift.dart';

import '../db/database.dart';
import 'device_label.dart';
import 'tokens.dart';

/// A freshly minted pair. The plaintext exists only here and in the response
/// that carries it; the database holds fingerprints.
class IssuedSession {
  const IssuedSession({
    required this.sessionId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String sessionId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
}

/// Why a refresh was refused.
enum RefreshFailure {
  /// No session holds this fingerprint — expired and swept, or never real.
  unknown,

  /// Past `refresh_expires_at`.
  expired,

  /// Explicitly ended by a logout, a password change, or an admin.
  revoked,

  /// Presented a token that had already been rotated away. Treated as theft.
  replayed,
}

/// Issues, validates, rotates and revokes sessions.
///
/// The design decision worth stating: tokens are **opaque and looked up**,
/// not self-describing like a JWT. That costs one indexed query per request,
/// and buys the thing a JWT cannot give — revocation that takes effect on the
/// very next request. Logout, "sign out everywhere", the admin's "revoke this
/// device" and the forced sign-out after a password change all depend on it.
class SessionService {
  SessionService({
    required this.db,
    required this.tokens,
    required this.accessTtl,
    required this.refreshTtl,
  });

  final AuthDatabase db;
  final TokenService tokens;
  final Duration accessTtl;
  final Duration refreshTtl;

  Future<IssuedSession> issue({
    required String userId,
    required int epoch,
    String? userAgent,
    String? ipAddress,
  }) async {
    final now = DateTime.now().toUtc();
    final accessToken = tokens.mint();
    final refreshToken = tokens.mint();
    final sessionId = newId();

    await db
        .into(db.sessions)
        .insert(
          SessionsCompanion.insert(
            id: sessionId,
            userId: userId,
            accessTokenHash: tokens.fingerprint(accessToken),
            refreshTokenHash: tokens.fingerprint(refreshToken),
            accessExpiresAt: now.add(accessTtl),
            refreshExpiresAt: now.add(refreshTtl),
            epoch: Value(epoch),
            deviceLabel: Value(describeDevice(userAgent)),
            ipAddress: Value(ipAddress),
            createdAt: now,
            lastUsedAt: now,
          ),
        );

    return IssuedSession(
      sessionId: sessionId,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessExpiresAt: now.add(accessTtl),
      refreshExpiresAt: now.add(refreshTtl),
    );
  }

  /// Resolves an access token to its session, or null if it cannot be used.
  ///
  /// Checks revocation, expiry and epoch. The epoch check is what makes
  /// "sign out everywhere" a single integer bump on the user row rather than
  /// a scan over session rows.
  Future<Session?> validateAccessToken(
    String accessToken,
    int userEpoch,
  ) async {
    final session =
        await (db.select(db.sessions)..where(
              (t) => t.accessTokenHash.equals(tokens.fingerprint(accessToken)),
            ))
            .getSingleOrNull();
    if (session == null) return null;
    if (session.revokedAt != null) return null;
    if (session.epoch != userEpoch) return null;
    if (session.accessExpiresAt.isBefore(DateTime.now().toUtc())) return null;
    return session;
  }

  /// Records that a session was just used, for the "last active" column.
  ///
  /// Only written when the stored value is more than a minute stale, so a
  /// chatty client does not turn every read into a write.
  Future<void> touch(Session session) async {
    final now = DateTime.now().toUtc();
    if (now.difference(session.lastUsedAt) < const Duration(minutes: 1)) return;
    await (db.update(db.sessions)..where((t) => t.id.equals(session.id))).write(
      SessionsCompanion(lastUsedAt: Value(now)),
    );
  }

  /// Exchanges a refresh token for a new pair, rotating it.
  ///
  /// The old session row is revoked and points at its successor. Presenting
  /// the old token again is therefore unambiguous replay rather than merely a
  /// stale request — and [RefreshFailure.replayed] is the caller's cue to kill
  /// the whole chain, because either the client or an attacker has a copy of
  /// a token that should no longer exist.
  Future<({IssuedSession? session, RefreshFailure? failure, Session? row})>
  rotate({
    required String refreshToken,
    required int userEpoch,
    String? userAgent,
    String? ipAddress,
  }) async {
    final fingerprint = tokens.fingerprint(refreshToken);
    final existing = await (db.select(
      db.sessions,
    )..where((t) => t.refreshTokenHash.equals(fingerprint))).getSingleOrNull();

    if (existing == null) {
      return (session: null, failure: RefreshFailure.unknown, row: null);
    }
    if (existing.rotatedToSessionId != null) {
      return (session: null, failure: RefreshFailure.replayed, row: existing);
    }
    if (existing.revokedAt != null) {
      return (session: null, failure: RefreshFailure.revoked, row: existing);
    }
    if (existing.epoch != userEpoch) {
      return (session: null, failure: RefreshFailure.revoked, row: existing);
    }
    if (existing.refreshExpiresAt.isBefore(DateTime.now().toUtc())) {
      return (session: null, failure: RefreshFailure.expired, row: existing);
    }

    final issued = await issue(
      userId: existing.userId,
      epoch: userEpoch,
      // Carry the original device label forward when the client sends none,
      // so a rotation does not silently rename a device to "Unknown".
      userAgent: userAgent,
      ipAddress: ipAddress ?? existing.ipAddress,
    );

    await (db.update(
      db.sessions,
    )..where((t) => t.id.equals(existing.id))).write(
      SessionsCompanion(
        revokedAt: Value(DateTime.now().toUtc()),
        revokedReason: const Value('rotated'),
        rotatedToSessionId: Value(issued.sessionId),
      ),
    );

    return (session: issued, failure: null, row: existing);
  }

  /// Live sessions for a user, newest first.
  Future<List<Session>> activeFor(String userId, int userEpoch) async {
    final now = DateTime.now().toUtc();
    return (db.select(db.sessions)
          ..where((t) => t.userId.equals(userId))
          ..where((t) => t.revokedAt.isNull())
          ..where((t) => t.epoch.equals(userEpoch))
          ..where((t) => t.refreshExpiresAt.isBiggerThanValue(now))
          ..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)]))
        .get();
  }

  Future<Session?> byId(String sessionId) => (db.select(
    db.sessions,
  )..where((t) => t.id.equals(sessionId))).getSingleOrNull();

  Future<void> revoke(String sessionId, String reason) async {
    await (db.update(db.sessions)
          ..where((t) => t.id.equals(sessionId))
          ..where((t) => t.revokedAt.isNull()))
        .write(
          SessionsCompanion(
            revokedAt: Value(DateTime.now().toUtc()),
            revokedReason: Value(reason),
          ),
        );
  }

  /// Ends every session for a user except optionally the one making the
  /// request, and returns how many were ended.
  Future<int> revokeAllFor(
    String userId, {
    String? exceptSessionId,
    required String reason,
  }) async {
    final statement = db.update(db.sessions)
      ..where((t) => t.userId.equals(userId))
      ..where((t) => t.revokedAt.isNull());
    if (exceptSessionId != null) {
      statement.where((t) => t.id.equals(exceptSessionId).not());
    }
    return statement.write(
      SessionsCompanion(
        revokedAt: Value(DateTime.now().toUtc()),
        revokedReason: Value(reason),
      ),
    );
  }

  /// Deletes sessions whose refresh window closed a while ago.
  ///
  /// Kept for a grace period rather than deleted at expiry so that a replayed
  /// token still finds its row and is reported as replay rather than as an
  /// unknown token.
  Future<int> purgeExpired({Duration keepFor = const Duration(days: 30)}) {
    final cutoff = DateTime.now().toUtc().subtract(keepFor);
    return (db.delete(
      db.sessions,
    )..where((t) => t.refreshExpiresAt.isSmallerThanValue(cutoff))).go();
  }
}
