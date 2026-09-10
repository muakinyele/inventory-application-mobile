import 'package:drift/drift.dart';

import '../db/database.dart';
import 'device_label.dart';
import 'tokens.dart';

/// Why a login was throttled before the password was even checked.
class ThrottleDecision {
  const ThrottleDecision({required this.throttled, this.retryAfter});

  final bool throttled;
  final Duration? retryAfter;

  static const allowed = ThrottleDecision(throttled: false);
}

/// Brute-force protection (§19).
///
/// Two independent limits, because they stop different attacks:
///
///  * **Per account** — consecutive failures lock one account for a fixed
///    window. Stops password guessing against a known user.
///  * **Per IP** — a sliding window over all attempts from one address, hit
///    or miss. Stops credential stuffing, which spreads a few guesses across
///    many accounts and would never trip a per-account counter.
///
/// Both are **time-bounded and self-healing**. There is no state an attacker
/// can push an account into that an administrator has to undo, which is the
/// explicit requirement in §19 — a lockout that had to be lifted by hand would
/// itself be a denial-of-service vector.
class LoginGuard {
  LoginGuard({
    required this.db,
    required this.maxFailedLogins,
    required this.lockoutDuration,
    this.ipAttemptLimit = 50,
    this.ipWindow = const Duration(minutes: 15),
  });

  final AuthDatabase db;

  /// Consecutive failures before an account is locked.
  final int maxFailedLogins;

  /// How long that lock lasts. It expires on its own.
  final Duration lockoutDuration;

  /// Attempts allowed from one IP inside [ipWindow]. Set well above normal
  /// use: an office behind one NAT address shares it, and locking out a whole
  /// building is worse than the attack.
  final int ipAttemptLimit;
  final Duration ipWindow;

  /// Checked before any credential work, so a throttled caller costs nothing.
  Future<ThrottleDecision> checkIp(String? ipAddress) async {
    if (ipAddress == null) return ThrottleDecision.allowed;

    final since = DateTime.now().toUtc().subtract(ipWindow);
    final count = db.loginAttempts.id.count();
    final query = db.selectOnly(db.loginAttempts)
      ..addColumns([count])
      ..where(db.loginAttempts.ipAddress.equals(ipAddress))
      ..where(db.loginAttempts.attemptedAt.isBiggerThanValue(since));
    final attempts = (await query.getSingle()).read(count) ?? 0;

    if (attempts < ipAttemptLimit) return ThrottleDecision.allowed;
    return ThrottleDecision(throttled: true, retryAfter: ipWindow);
  }

  /// A deliberate delay that grows with recent failures.
  ///
  /// Cheap for a real user who mistyped once, expensive for a script. Capped
  /// so it can never become a way to tie up server threads.
  Duration backoffFor(int consecutiveFailures) {
    if (consecutiveFailures <= 1) return Duration.zero;
    final milliseconds = 100 * (1 << (consecutiveFailures - 2).clamp(0, 6));
    return Duration(milliseconds: milliseconds.clamp(0, 3000));
  }

  bool isLocked(User user) {
    final until = user.lockedUntil;
    return until != null && until.isAfter(DateTime.now().toUtc());
  }

  Duration remainingLockout(User user) {
    final until = user.lockedUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Records a failure and locks the account once the threshold is reached.
  ///
  /// Returns true when this attempt is the one that triggered the lock, so the
  /// caller can send the notification exactly once rather than on every
  /// subsequent attempt.
  Future<bool> registerFailure(User user) async {
    final failures = user.failedLoginCount + 1;
    final shouldLock = failures >= maxFailedLogins;

    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        failedLoginCount: Value(failures),
        lockedUntil: shouldLock
            ? Value(DateTime.now().toUtc().add(lockoutDuration))
            : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return shouldLock && !isLocked(user);
  }

  /// Clears the counter after a successful sign-in.
  Future<void> registerSuccess(User user) async {
    await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        failedLoginCount: const Value(0),
        lockedUntil: const Value(null),
        lastLoginAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Lets an administrator lift a lock early (§19).
  Future<void> unlock(String userId) async {
    await (db.update(db.users)..where((t) => t.id.equals(userId))).write(
      UsersCompanion(
        failedLoginCount: const Value(0),
        lockedUntil: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Appends to the attempt log, which feeds both the throttle above and the
  /// "recent activity" list on the user's own security page (§17).
  Future<void> log({
    required String email,
    required bool succeeded,
    String? userId,
    String? failureReason,
    String? ipAddress,
    String? userAgent,
  }) async {
    await db
        .into(db.loginAttempts)
        .insert(
          LoginAttemptsCompanion.insert(
            id: newId(),
            userId: Value(userId),
            email: email,
            succeeded: succeeded,
            failureReason: Value(failureReason),
            ipAddress: Value(ipAddress),
            deviceLabel: Value(describeDevice(userAgent)),
            attemptedAt: DateTime.now().toUtc(),
          ),
        );
  }

  /// Recent attempts for one user, for the security screen.
  Future<List<LoginAttempt>> recentFor(String userId, {int limit = 20}) {
    return (db.select(db.loginAttempts)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.attemptedAt),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
  }

  /// Trims the attempt log. Called on a timer by the server.
  Future<int> purgeOlderThan(Duration age) {
    final cutoff = DateTime.now().toUtc().subtract(age);
    return (db.delete(
      db.loginAttempts,
    )..where((t) => t.attemptedAt.isSmallerThanValue(cutoff))).go();
  }
}
