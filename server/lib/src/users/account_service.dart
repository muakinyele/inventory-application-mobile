import 'package:drift/drift.dart';

import '../audit/audit_actions.dart';
import '../audit/audit_service.dart';
import '../auth/auth_service.dart';
import '../auth/login_guard.dart';
import '../auth/passwords.dart';
import '../auth/session_service.dart';
import '../auth/token_store.dart';
import '../config/env.dart';
import '../db/database.dart';
import '../email/notification_service.dart';
import '../email/templates.dart';
import '../rbac/principal.dart';
import 'user_service.dart';

/// Why a self-service change was refused.
enum AccountError {
  wrongPassword,
  emailInUse,
  invalidEmail,
  notFound,
  tokenBad,
}

/// What a signed-in user can change about themselves (§16, §17).
///
/// Kept apart from [UserService] because the rules genuinely differ: a user
/// may edit their own name freely but must prove control of a new address
/// before it takes effect, and may never change their own role.
class AccountService {
  AccountService({
    required this.db,
    required this.env,
    required this.audit,
    required this.tokenStore,
    required this.sessions,
    required this.guard,
    required this.notifications,
    required this.templates,
    required this.hasher,
  });

  final AuthDatabase db;
  final Env env;
  final AuditService audit;
  final TokenStore tokenStore;
  final SessionService sessions;
  final LoginGuard guard;
  final NotificationService notifications;
  final EmailTemplates templates;
  final PasswordHasher hasher;

  Future<User?> updateProfile({
    required Principal principal,
    String? name,
    String? phone,
    String? ipAddress,
  }) async {
    await (db.update(db.users)..where((t) => t.id.equals(principal.id))).write(
      UsersCompanion(
        name: name == null || name.trim().isEmpty
            ? const Value.absent()
            : Value(name.trim()),
        phone: phone == null ? const Value.absent() : Value(phone.trim()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await audit.record(
      action: AuditAction.profileUpdated,
      actorId: principal.id,
      actorEmail: principal.email,
      targetType: 'user',
      targetId: principal.id,
      metadata: {
        'fields': [if (name != null) 'name', if (phone != null) 'phone'],
      },
      ipAddress: ipAddress,
    );
    return (db.select(
      db.users,
    )..where((t) => t.id.equals(principal.id))).getSingleOrNull();
  }

  /// Starts an email change (§16).
  ///
  /// Three deliberate choices here:
  ///  * The current password is required, so someone who walks up to an
  ///    unlocked laptop cannot quietly move the account to their own address.
  ///  * The address is *not* written to the user row yet. It rides in the
  ///    token's payload until the new mailbox proves it can receive mail.
  ///  * The confirmation goes to the **new** address, and a notice of the
  ///    attempt goes to the old one.
  Future<AccountError?> requestEmailChange({
    required Principal principal,
    required String newEmail,
    required String currentPassword,
    String? ipAddress,
  }) async {
    final user = await (db.select(
      db.users,
    )..where((t) => t.id.equals(principal.id))).getSingleOrNull();
    final storedHash = user?.passwordHash;
    if (user == null || storedHash == null) return AccountError.notFound;

    if (!await hasher.verify(currentPassword, storedHash)) {
      return AccountError.wrongPassword;
    }

    final normalised = normaliseEmail(newEmail);
    if (!isPlausibleEmail(normalised)) return AccountError.invalidEmail;
    if (normalised == user.email) return null; // Nothing to do.

    final taken =
        await (db.select(db.users)
              ..where((t) => t.email.equals(normalised))
              ..where((t) => t.deletedAt.isNull()))
            .getSingleOrNull();
    if (taken != null) return AccountError.emailInUse;

    final token = await tokenStore.issue(
      userId: user.id,
      purpose: TokenPurpose.emailChange,
      validFor: env.emailVerificationTtl,
      payload: normalised,
    );

    await notifications.sendSecurity(
      templates.emailChange(
        to: normalised,
        name: user.name,
        verifyUrl: '${env.appUrl}/#/verify-email-change?token=$token',
        validFor: env.emailVerificationTtl,
      ),
    );
    await audit.record(
      action: AuditAction.emailChangeRequested,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      // The destination is recorded because an admin investigating an account
      // takeover needs to see where someone tried to move the account.
      metadata: {'to': normalised},
      ipAddress: ipAddress,
    );
    return null;
  }

  /// Completes an email change once the new address has been proven.
  Future<AccountError?> confirmEmailChange({
    required String token,
    String? ipAddress,
  }) async {
    final peeked = await tokenStore.peek(
      token: token,
      purpose: TokenPurpose.emailChange,
    );
    if (peeked.rejection != null) return AccountError.tokenBad;

    final row = peeked.token!;
    final newEmail = row.payload;
    if (newEmail == null) return AccountError.tokenBad;

    final user = await (db.select(
      db.users,
    )..where((t) => t.id.equals(row.userId))).getSingleOrNull();
    if (user == null || user.deletedAt != null) return AccountError.notFound;

    // Re-checked at redemption: the address may have been claimed by someone
    // else between the request and the click.
    final taken =
        await (db.select(db.users)
              ..where((t) => t.email.equals(newEmail))
              ..where((t) => t.deletedAt.isNull()))
            .getSingleOrNull();
    if (taken != null && taken.id != user.id) return AccountError.emailInUse;

    final consumed = await tokenStore.consume(
      token: token,
      purpose: TokenPurpose.emailChange,
    );
    if (consumed.rejection != null) return AccountError.tokenBad;

    final previous = user.email;
    final now = DateTime.now().toUtc();
    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        email: Value(newEmail),
        emailVerified: const Value(true),
        emailVerifiedAt: Value(now),
        updatedAt: Value(now),
      ),
    );

    // The old mailbox is told after the fact — it is the only channel that
    // still reaches the original owner if this change was not theirs.
    await notifications.sendSecurity(
      templates.emailChanged(to: previous, name: user.name, newEmail: newEmail),
    );

    await audit.record(
      action: AuditAction.emailChanged,
      actorId: user.id,
      actorEmail: newEmail,
      targetType: 'user',
      targetId: user.id,
      metadata: {'from': previous, 'to': newEmail},
      ipAddress: ipAddress,
    );
    return null;
  }

  /// The user's own live sessions, with the current one marked (§18).
  Future<List<({Session session, bool isCurrent})>> activeSessions(
    Principal principal,
  ) async {
    final rows = await sessions.activeFor(
      principal.id,
      principal.user.sessionEpoch,
    );
    return [
      for (final session in rows)
        (session: session, isCurrent: session.id == principal.sessionId),
    ];
  }

  /// Ends one of the user's own sessions. Returns false if it is not theirs —
  /// which is what stops a session id from another account being revoked by
  /// guessing.
  Future<bool> revokeOwnSession({
    required Principal principal,
    required String sessionId,
    String? ipAddress,
  }) async {
    final session = await sessions.byId(sessionId);
    if (session == null || session.userId != principal.id) return false;
    if (session.revokedAt != null) return false;

    await sessions.revoke(sessionId, 'revoked_by_user');
    await audit.record(
      action: AuditAction.sessionRevoked,
      actorId: principal.id,
      actorEmail: principal.email,
      targetType: 'session',
      targetId: sessionId,
      metadata: {'device': session.deviceLabel, 'self': true},
      ipAddress: ipAddress,
    );
    return true;
  }

  /// Recent sign-in activity for the security page (§17).
  Future<List<LoginAttempt>> recentActivity(Principal principal) =>
      guard.recentFor(principal.id);

  Future<Map<String, bool>> notificationPreferences(Principal principal) =>
      notifications.preferencesFor(principal.id);

  /// Updates application-notification settings.
  ///
  /// Unknown keys are ignored rather than erroring, and there is no key for
  /// any security notification, so this endpoint structurally cannot switch
  /// one off (§14).
  Future<Map<String, bool>> setNotificationPreferences({
    required Principal principal,
    required Map<String, bool> preferences,
    String? ipAddress,
  }) async {
    final applied = <String>[];
    for (final entry in preferences.entries) {
      final ok = await notifications.setPreference(
        userId: principal.id,
        channel: entry.key,
        enabled: entry.value,
      );
      if (ok) applied.add(entry.key);
    }
    if (applied.isNotEmpty) {
      await audit.record(
        action: AuditAction.notificationPreferencesChanged,
        actorId: principal.id,
        actorEmail: principal.email,
        targetType: 'user',
        targetId: principal.id,
        metadata: {'channels': applied},
        ipAddress: ipAddress,
      );
    }
    return notifications.preferencesFor(principal.id);
  }
}
