import 'package:drift/drift.dart';

import '../audit/audit_actions.dart';
import '../audit/audit_service.dart';
import '../config/env.dart';
import '../db/database.dart';
import '../email/notification_service.dart';
import '../email/templates.dart';
import '../rbac/access_service.dart';
import '../rbac/principal.dart';
import 'device_label.dart';
import 'login_guard.dart';
import 'password_policy.dart';
import 'passwords.dart';
import 'session_service.dart';
import 'token_store.dart';
import 'tokens.dart';

/// Why a sign-in was refused.
///
/// The API deliberately collapses several of these into one message for the
/// client; the distinction is kept here so the audit trail stays precise.
enum LoginRejection {
  invalidCredentials,
  accountDisabled,
  accountPending,
  emailUnverified,
  accountLocked,
  throttled,
}

sealed class LoginOutcome {
  const LoginOutcome();
}

class LoginSucceeded extends LoginOutcome {
  const LoginSucceeded({required this.principal, required this.session});
  final Principal principal;
  final IssuedSession session;
}

class LoginRejected extends LoginOutcome {
  const LoginRejected(this.reason, {this.retryAfter});
  final LoginRejection reason;
  final Duration? retryAfter;
}

/// Result of redeeming a one-time link.
class TokenOutcome {
  const TokenOutcome.ok() : rejection = null, problems = const [];
  const TokenOutcome.rejected(this.rejection) : problems = const [];
  const TokenOutcome.invalidPassword(this.problems) : rejection = null;

  final TokenRejection? rejection;
  final List<String> problems;

  bool get isSuccess => rejection == null && problems.isEmpty;
}

/// Everything that happens on the credential paths.
///
/// Account administration lives in `UserService`; profile edits live in
/// `AccountService`. This class is only the parts where a password or a
/// one-time token is in play, which keeps the security-critical surface in one
/// readable file.
class AuthService {
  AuthService({
    required this.db,
    required this.env,
    required this.hasher,
    required this.policy,
    required this.tokenStore,
    required this.sessions,
    required this.access,
    required this.guard,
    required this.audit,
    required this.notifications,
    required this.templates,
  });

  final AuthDatabase db;
  final Env env;
  final PasswordHasher hasher;
  final PasswordPolicy policy;
  final TokenStore tokenStore;
  final SessionService sessions;
  final AccessService access;
  final LoginGuard guard;
  final AuditService audit;
  final NotificationService notifications;
  final EmailTemplates templates;

  /// A real Argon2id hash of a value nobody knows.
  ///
  /// Verified against when no account matches, so a request for a
  /// non-existent address costs the same time as one for a real address with
  /// the wrong password. Without this, response latency is a free account
  /// enumeration oracle — the generic error message alone does not close it.
  String? _decoyHash;

  Future<String> _decoy() async =>
      _decoyHash ??= await hasher.hash('decoy-${newId()}');

  // -------------------------------------------------------------------
  // Sign in
  // -------------------------------------------------------------------

  Future<LoginOutcome> login({
    required String email,
    required String password,
    String? ipAddress,
    String? userAgent,
  }) async {
    final normalised = normaliseEmail(email);

    final throttle = await guard.checkIp(ipAddress);
    if (throttle.throttled) {
      await guard.log(
        email: normalised,
        succeeded: false,
        failureReason: 'throttled',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      return LoginRejected(
        LoginRejection.throttled,
        retryAfter: throttle.retryAfter,
      );
    }

    final user = await findByEmail(normalised);

    if (user == null) {
      // Spend the same time as a real verification would.
      await hasher.verify(password, await _decoy());
      await guard.log(
        email: normalised,
        succeeded: false,
        failureReason: 'no_account',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      await audit.record(
        action: AuditAction.loginFailed,
        actorEmail: normalised,
        result: 'failure',
        metadata: const {'reason': 'no_account'},
        ipAddress: ipAddress,
      );
      return const LoginRejected(LoginRejection.invalidCredentials);
    }

    if (guard.isLocked(user)) {
      await guard.log(
        email: normalised,
        succeeded: false,
        userId: user.id,
        failureReason: 'locked',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      return LoginRejected(
        LoginRejection.accountLocked,
        retryAfter: guard.remainingLockout(user),
      );
    }

    if (user.status == 'disabled') {
      await guard.log(
        email: normalised,
        succeeded: false,
        userId: user.id,
        failureReason: 'disabled',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      await audit.record(
        action: AuditAction.loginFailed,
        actorId: user.id,
        actorEmail: user.email,
        result: 'failure',
        metadata: const {'reason': 'disabled'},
        ipAddress: ipAddress,
      );
      return const LoginRejected(LoginRejection.accountDisabled);
    }

    final storedHash = user.passwordHash;
    if (storedHash == null) {
      // Invited but never claimed: there is nothing to verify against.
      await hasher.verify(password, await _decoy());
      await guard.log(
        email: normalised,
        succeeded: false,
        userId: user.id,
        failureReason: 'pending',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      return const LoginRejected(LoginRejection.accountPending);
    }

    // Slows a guessing run without inconveniencing someone who mistyped once.
    final backoff = guard.backoffFor(user.failedLoginCount);
    if (backoff > Duration.zero) await Future<void>.delayed(backoff);

    if (!await hasher.verify(password, storedHash)) {
      final justLocked = await guard.registerFailure(user);
      await guard.log(
        email: normalised,
        succeeded: false,
        userId: user.id,
        failureReason: 'bad_password',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      await audit.record(
        action: AuditAction.loginFailed,
        actorId: user.id,
        actorEmail: user.email,
        result: 'failure',
        metadata: {'reason': 'bad_password', 'locked': justLocked},
        ipAddress: ipAddress,
      );

      if (justLocked) {
        await audit.record(
          action: AuditAction.accountLocked,
          actorId: user.id,
          actorEmail: user.email,
          targetType: 'user',
          targetId: user.id,
          metadata: {'minutes': env.lockoutDuration.inMinutes},
          ipAddress: ipAddress,
        );
        await notifications.sendSecurity(
          templates.accountLocked(
            to: user.email,
            name: user.name,
            lockedFor: env.lockoutDuration,
          ),
        );
        return LoginRejected(
          LoginRejection.accountLocked,
          retryAfter: env.lockoutDuration,
        );
      }
      return const LoginRejected(LoginRejection.invalidCredentials);
    }

    // Correct password from here on.

    if (user.status == 'pending') {
      return const LoginRejected(LoginRejection.accountPending);
    }
    if (!user.emailVerified) {
      await guard.log(
        email: normalised,
        succeeded: false,
        userId: user.id,
        failureReason: 'unverified',
        ipAddress: ipAddress,
        userAgent: userAgent,
      );
      return const LoginRejected(LoginRejection.emailUnverified);
    }

    // The one moment the plaintext is legitimately in hand, so it is also the
    // only chance to upgrade a hash made with weaker parameters.
    if (hasher.needsRehash(storedHash)) {
      final upgraded = await hasher.hash(password);
      await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
        UsersCompanion(passwordHash: Value(upgraded)),
      );
    }

    final isNewDevice = await _isUnrecognisedDevice(user.id, userAgent);

    await guard.registerSuccess(user);
    await guard.log(
      email: normalised,
      succeeded: true,
      userId: user.id,
      ipAddress: ipAddress,
      userAgent: userAgent,
    );

    final issued = await sessions.issue(
      userId: user.id,
      epoch: user.sessionEpoch,
      userAgent: userAgent,
      ipAddress: ipAddress,
    );

    await audit.record(
      action: AuditAction.login,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'session',
      targetId: issued.sessionId,
      ipAddress: ipAddress,
    );

    if (isNewDevice) {
      await notifications.sendSecurity(
        templates.newLogin(
          to: user.email,
          name: user.name,
          when: DateTime.now().toUtc(),
          deviceLabel: describeDevice(userAgent),
          ipAddress: ipAddress,
          securityUrl: '${env.appUrl}/#/account/security',
        ),
      );
    }

    final resolved = await access.resolve(user.id);
    return LoginSucceeded(
      principal: Principal(
        user: user,
        sessionId: issued.sessionId,
        roleKeys: resolved.roles,
        permissions: resolved.permissions,
      ),
      session: issued,
    );
  }

  /// True when no earlier session for this user carried the same device
  /// label, which is what makes the "new sign-in" notice meaningful rather
  /// than an alert on every single login.
  Future<bool> _isUnrecognisedDevice(String userId, String? userAgent) async {
    final label = describeDevice(userAgent);
    final seen =
        await (db.select(db.sessions)
              ..where((t) => t.userId.equals(userId))
              ..where((t) => t.deviceLabel.equals(label))
              ..limit(1))
            .getSingleOrNull();
    return seen == null;
  }

  // -------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------

  /// Resolves a bearer token to a [Principal], or null.
  ///
  /// Called on every authenticated request, so it is deliberately two indexed
  /// lookups plus the permission resolution and nothing else.
  Future<Principal?> authenticate(String accessToken) async {
    final fingerprint = sessions.tokens.fingerprint(accessToken);
    final session = await (db.select(
      db.sessions,
    )..where((t) => t.accessTokenHash.equals(fingerprint))).getSingleOrNull();
    if (session == null) return null;
    if (session.revokedAt != null) return null;
    if (session.accessExpiresAt.isBefore(DateTime.now().toUtc())) return null;

    final user = await (db.select(
      db.users,
    )..where((t) => t.id.equals(session.userId))).getSingleOrNull();
    if (user == null) return null;
    if (user.deletedAt != null) return null;
    if (user.status != 'active') return null;
    // A password change or "sign out everywhere" bumps the epoch, which kills
    // every token minted before it without touching a single session row.
    if (session.epoch != user.sessionEpoch) return null;

    await sessions.touch(session);

    final resolved = await access.resolve(user.id);
    return Principal(
      user: user,
      sessionId: session.id,
      roleKeys: resolved.roles,
      permissions: resolved.permissions,
    );
  }

  Future<({IssuedSession? session, RefreshFailure? failure})> refresh({
    required String refreshToken,
    String? ipAddress,
    String? userAgent,
  }) async {
    // Find the owning user first: the epoch check needs it, and a token whose
    // user is gone must fail closed.
    final fingerprint = sessions.tokens.fingerprint(refreshToken);
    final row = await (db.select(
      db.sessions,
    )..where((t) => t.refreshTokenHash.equals(fingerprint))).getSingleOrNull();
    if (row == null) {
      return (session: null, failure: RefreshFailure.unknown);
    }

    final user = await (db.select(
      db.users,
    )..where((t) => t.id.equals(row.userId))).getSingleOrNull();
    if (user == null || user.deletedAt != null || user.status != 'active') {
      return (session: null, failure: RefreshFailure.revoked);
    }

    final result = await sessions.rotate(
      refreshToken: refreshToken,
      userEpoch: user.sessionEpoch,
      userAgent: userAgent,
      ipAddress: ipAddress,
    );

    if (result.failure == RefreshFailure.replayed) {
      // A token that was already exchanged has been presented again. Either
      // the client is confused or someone has a stolen copy; both are handled
      // the same way, by ending every session for the account and forcing a
      // fresh sign-in.
      await sessions.revokeAllFor(user.id, reason: 'refresh_replay');
      await audit.record(
        action: AuditAction.refreshReplayed,
        actorId: user.id,
        actorEmail: user.email,
        targetType: 'session',
        targetId: row.id,
        result: 'failure',
        ipAddress: ipAddress,
      );
      return (session: null, failure: RefreshFailure.replayed);
    }

    if (result.session != null) {
      await audit.record(
        action: AuditAction.tokenRefreshed,
        actorId: user.id,
        actorEmail: user.email,
        targetType: 'session',
        targetId: result.session!.sessionId,
        ipAddress: ipAddress,
      );
    }
    return (session: result.session, failure: result.failure);
  }

  Future<void> logout(Principal principal, {String? ipAddress}) async {
    await sessions.revoke(principal.sessionId, 'logout');
    await audit.record(
      action: AuditAction.logout,
      actorId: principal.id,
      actorEmail: principal.email,
      targetType: 'session',
      targetId: principal.sessionId,
      ipAddress: ipAddress,
    );
  }

  Future<int> logoutEverywhere(
    Principal principal, {
    bool keepCurrent = false,
    String? ipAddress,
  }) async {
    final revoked = await sessions.revokeAllFor(
      principal.id,
      exceptSessionId: keepCurrent ? principal.sessionId : null,
      reason: 'logout_all',
    );
    await audit.record(
      action: AuditAction.logoutAll,
      actorId: principal.id,
      actorEmail: principal.email,
      targetType: 'user',
      targetId: principal.id,
      metadata: {'revoked': revoked, 'keptCurrent': keepCurrent},
      ipAddress: ipAddress,
    );
    return revoked;
  }

  // -------------------------------------------------------------------
  // Passwords
  // -------------------------------------------------------------------

  /// Starts a reset.
  ///
  /// Returns nothing and reveals nothing. The caller always answers with the
  /// same generic sentence whether or not the address matched (§10, §27), and
  /// this method is careful to take a similar amount of time either way.
  Future<void> requestPasswordReset({
    required String email,
    String? ipAddress,
  }) async {
    final normalised = normaliseEmail(email);
    final user = await findByEmail(normalised);

    if (user == null || user.status == 'disabled') {
      await audit.record(
        action: AuditAction.passwordResetRequested,
        actorEmail: normalised,
        result: 'failure',
        metadata: const {'reason': 'no_eligible_account'},
        ipAddress: ipAddress,
      );
      return;
    }

    // Cheap ceiling on using the endpoint as a mail cannon against one
    // address. The response is unchanged, so it leaks nothing.
    final recent = await tokenStore.issuedSince(
      userId: user.id,
      purpose: TokenPurpose.passwordReset,
      window: const Duration(minutes: 15),
    );
    if (recent >= 3) return;

    final token = await tokenStore.issue(
      userId: user.id,
      purpose: TokenPurpose.passwordReset,
      validFor: env.passwordResetTtl,
    );

    await notifications.sendSecurity(
      templates.passwordReset(
        to: user.email,
        name: user.name,
        resetUrl: '${env.appUrl}/#/reset-password?token=$token',
        validFor: env.passwordResetTtl,
      ),
    );
    await audit.record(
      action: AuditAction.passwordResetRequested,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
  }

  Future<TokenOutcome> resetPassword({
    required String token,
    required String newPassword,
    String? ipAddress,
  }) async {
    final peeked = await tokenStore.peek(
      token: token,
      purpose: TokenPurpose.passwordReset,
    );
    if (peeked.rejection != null) {
      return TokenOutcome.rejected(peeked.rejection!);
    }

    final user = await byId(peeked.token!.userId);
    if (user == null) {
      return const TokenOutcome.rejected(TokenRejection.unknown);
    }

    final check = policy.check(
      newPassword,
      email: user.email,
      name: user.name,
      appName: env.appName,
    );
    // Validated before the token is spent, so a rejected password does not
    // cost the user their link.
    if (!check.isAcceptable) {
      return TokenOutcome.invalidPassword(check.problems);
    }

    final consumed = await tokenStore.consume(
      token: token,
      purpose: TokenPurpose.passwordReset,
    );
    if (consumed.rejection != null) {
      return TokenOutcome.rejected(consumed.rejection!);
    }

    await _applyNewPassword(user, newPassword);
    // Completing a reset proves control of the mailbox, so it also settles
    // verification for an account that had never confirmed its address.
    if (!user.emailVerified) {
      await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
        UsersCompanion(
          emailVerified: const Value(true),
          emailVerifiedAt: Value(DateTime.now().toUtc()),
          status: const Value('active'),
        ),
      );
    }

    await audit.record(
      action: AuditAction.passwordResetCompleted,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
    await notifications.sendSecurity(
      templates.passwordChanged(
        to: user.email,
        name: user.name,
        when: DateTime.now().toUtc(),
        ipAddress: ipAddress,
        otherSessionsRevoked: true,
      ),
    );
    return const TokenOutcome.ok();
  }

  /// Changes the password of a signed-in user (§10).
  ///
  /// Returns null on success, or the list of problems to show.
  Future<({bool ok, bool wrongCurrent, List<String> problems})> changePassword({
    required Principal principal,
    required String currentPassword,
    required String newPassword,
    String? ipAddress,
  }) async {
    final user = await byId(principal.id);
    final storedHash = user?.passwordHash;
    if (user == null || storedHash == null) {
      return (ok: false, wrongCurrent: true, problems: const <String>[]);
    }

    if (!await hasher.verify(currentPassword, storedHash)) {
      await audit.record(
        action: AuditAction.passwordChanged,
        actorId: user.id,
        actorEmail: user.email,
        result: 'failure',
        metadata: const {'reason': 'wrong_current_password'},
        ipAddress: ipAddress,
      );
      return (ok: false, wrongCurrent: true, problems: const <String>[]);
    }

    final check = policy.check(
      newPassword,
      email: user.email,
      name: user.name,
      appName: env.appName,
    );
    if (!check.isAcceptable) {
      return (ok: false, wrongCurrent: false, problems: check.problems);
    }

    await _applyNewPassword(user, newPassword);

    await audit.record(
      action: AuditAction.passwordChanged,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
    await notifications.sendSecurity(
      templates.passwordChanged(
        to: user.email,
        name: user.name,
        when: DateTime.now().toUtc(),
        ipAddress: ipAddress,
        otherSessionsRevoked: true,
      ),
    );
    return (ok: true, wrongCurrent: false, problems: const <String>[]);
  }

  /// Writes a new hash and invalidates every existing session by bumping the
  /// epoch.
  ///
  /// The caller is expected to issue a fresh session afterwards if the user is
  /// meant to stay signed in on *this* device — which is what the change-
  /// password endpoint does.
  Future<void> _applyNewPassword(User user, String newPassword) async {
    final hash = await hasher.hash(newPassword);
    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        passwordHash: Value(hash),
        sessionEpoch: Value(user.sessionEpoch + 1),
        failedLoginCount: const Value(0),
        lockedUntil: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await sessions.revokeAllFor(user.id, reason: 'password_changed');
    // Any outstanding reset link is now moot and must not stay live.
    await tokenStore.invalidateOutstanding(
      userId: user.id,
      purpose: TokenPurpose.passwordReset,
    );
  }

  // -------------------------------------------------------------------
  // Invitations and verification
  // -------------------------------------------------------------------

  /// Details behind an invitation link, so the accept page can greet the user
  /// by name without them having signed in.
  Future<({User? user, TokenRejection? rejection})> inspectInvitation(
    String token,
  ) async {
    final peeked = await tokenStore.peek(
      token: token,
      purpose: TokenPurpose.invitation,
    );
    if (peeked.rejection != null) {
      return (user: null, rejection: peeked.rejection);
    }
    return (user: await byId(peeked.token!.userId), rejection: null);
  }

  /// Claims an invitation: sets the password, activates the account, and marks
  /// the address verified — receiving the link is itself proof of control.
  Future<TokenOutcome> acceptInvitation({
    required String token,
    required String password,
    String? name,
    String? ipAddress,
  }) async {
    final peeked = await tokenStore.peek(
      token: token,
      purpose: TokenPurpose.invitation,
    );
    if (peeked.rejection != null) {
      return TokenOutcome.rejected(peeked.rejection!);
    }

    final user = await byId(peeked.token!.userId);
    if (user == null) {
      return const TokenOutcome.rejected(TokenRejection.unknown);
    }

    final check = policy.check(
      password,
      email: user.email,
      name: name ?? user.name,
      appName: env.appName,
    );
    if (!check.isAcceptable) {
      return TokenOutcome.invalidPassword(check.problems);
    }

    final consumed = await tokenStore.consume(
      token: token,
      purpose: TokenPurpose.invitation,
    );
    if (consumed.rejection != null) {
      return TokenOutcome.rejected(consumed.rejection!);
    }

    final now = DateTime.now().toUtc();
    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        passwordHash: Value(await hasher.hash(password)),
        name: name == null || name.trim().isEmpty
            ? const Value.absent()
            : Value(name.trim()),
        status: const Value('active'),
        emailVerified: const Value(true),
        emailVerifiedAt: Value(now),
        updatedAt: Value(now),
      ),
    );

    await audit.record(
      action: AuditAction.invitationAccepted,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
    return const TokenOutcome.ok();
  }

  Future<TokenOutcome> verifyEmail({
    required String token,
    String? ipAddress,
  }) async {
    final consumed = await tokenStore.consume(
      token: token,
      purpose: TokenPurpose.emailVerification,
    );
    if (consumed.rejection != null) {
      return TokenOutcome.rejected(consumed.rejection!);
    }

    final user = await byId(consumed.token!.userId);
    if (user == null) {
      return const TokenOutcome.rejected(TokenRejection.unknown);
    }

    final now = DateTime.now().toUtc();
    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        emailVerified: const Value(true),
        emailVerifiedAt: Value(now),
        // An account that was only waiting on verification becomes usable.
        status: user.status == 'pending' && user.passwordHash != null
            ? const Value('active')
            : const Value.absent(),
        updatedAt: Value(now),
      ),
    );

    await audit.record(
      action: AuditAction.emailVerified,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
    return const TokenOutcome.ok();
  }

  /// Re-sends a verification link.
  ///
  /// Rate-limited per account, and the caller always reports the same generic
  /// success so the endpoint cannot be used to test whether an address exists.
  Future<void> resendVerification({
    required String email,
    String? ipAddress,
  }) async {
    final user = await findByEmail(normaliseEmail(email));
    if (user == null || user.emailVerified || user.status == 'disabled') return;

    final recent = await tokenStore.issuedSince(
      userId: user.id,
      purpose: TokenPurpose.emailVerification,
      window: const Duration(minutes: 15),
    );
    if (recent >= 3) return;

    final token = await tokenStore.issue(
      userId: user.id,
      purpose: TokenPurpose.emailVerification,
      validFor: env.emailVerificationTtl,
    );
    await notifications.sendSecurity(
      templates.verifyEmail(
        to: user.email,
        name: user.name,
        verifyUrl: '${env.appUrl}/#/verify-email?token=$token',
        validFor: env.emailVerificationTtl,
      ),
    );
    await audit.record(
      action: AuditAction.emailVerificationSent,
      actorId: user.id,
      actorEmail: user.email,
      targetType: 'user',
      targetId: user.id,
      ipAddress: ipAddress,
    );
  }

  // -------------------------------------------------------------------
  // Lookups
  // -------------------------------------------------------------------

  Future<User?> findByEmail(String email) {
    return (db.select(db.users)
          ..where((t) => t.email.equals(email))
          ..where((t) => t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<User?> byId(String id) {
    return (db.select(db.users)
          ..where((t) => t.id.equals(id))
          ..where((t) => t.deletedAt.isNull()))
        .getSingleOrNull();
  }
}

/// Addresses are compared and stored in one canonical form, so `A@x.com` and
/// `a@x.com` cannot become two accounts.
String normaliseEmail(String email) => email.trim().toLowerCase();
