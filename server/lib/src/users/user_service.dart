import 'package:drift/drift.dart';

import '../audit/audit_actions.dart';
import '../audit/audit_service.dart';
import '../auth/auth_service.dart';
import '../auth/login_guard.dart';
import '../auth/passwords.dart';
import '../auth/session_service.dart';
import '../auth/token_store.dart';
import '../auth/tokens.dart';
import '../config/env.dart';
import '../db/database.dart';
import '../email/notification_service.dart';
import '../email/templates.dart';
import '../rbac/access_service.dart';
import '../rbac/permissions.dart';
import '../rbac/principal.dart';

/// A user plus the derived facts the admin list shows, assembled once rather
/// than by the caller issuing an N+1 query per row.
class UserSummary {
  const UserSummary({
    required this.user,
    required this.roleKeys,
    required this.roleNames,
    required this.activeSessions,
  });

  final User user;
  final List<String> roleKeys;
  final List<String> roleNames;
  final int activeSessions;
}

class UserPage {
  const UserPage({required this.users, required this.total});
  final List<UserSummary> users;
  final int total;
}

/// Why an administrative change was refused.
enum UserMutationError {
  notFound,
  emailInUse,
  invalidEmail,
  invalidRole,
  invalidPermission,
  lastAdministrator,
  cannotTargetSelf,
}

class UserMutation {
  const UserMutation.ok(this.user) : error = null;
  const UserMutation.failed(this.error) : user = null;

  final User? user;
  final UserMutationError? error;

  bool get isSuccess => error == null;
}

/// Administration of other people's accounts (§8, §9).
///
/// Every method here is reached only through a permission check in the router;
/// the service assumes the caller is already authorised and concerns itself
/// with the invariants the API cannot express — chiefly that the system must
/// never end up with no administrator who can sign in.
class UserService {
  UserService({
    required this.db,
    required this.env,
    required this.access,
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
  final AccessService access;
  final AuditService audit;
  final TokenStore tokenStore;
  final SessionService sessions;
  final LoginGuard guard;
  final NotificationService notifications;
  final EmailTemplates templates;
  final PasswordHasher hasher;

  // -------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------

  /// The admin list: searched, filtered, paged (§8).
  Future<UserPage> list({
    String? search,
    String? status,
    String? roleKey,
    bool includeDeleted = false,
    int limit = 25,
    int offset = 0,
  }) async {
    // Role filtering needs a join, so the id set is narrowed first and the
    // main query stays a simple, indexable predicate.
    Set<String>? idsWithRole;
    if (roleKey != null) {
      final rows = await (db.select(db.userRoles).join([
        innerJoin(db.roles, db.roles.id.equalsExp(db.userRoles.roleId)),
      ])..where(db.roles.key.equals(roleKey))).get();
      idsWithRole = rows.map((r) => r.readTable(db.userRoles).userId).toSet();
      if (idsWithRole.isEmpty) return const UserPage(users: [], total: 0);
    }

    Expression<bool> filter($UsersTable t) {
      var predicate = const Constant(true) as Expression<bool>;
      if (!includeDeleted) predicate = predicate & t.deletedAt.isNull();
      if (status != null) predicate = predicate & t.status.equals(status);
      if (idsWithRole != null) predicate = predicate & t.id.isIn(idsWithRole);
      if (search != null && search.trim().isNotEmpty) {
        final term = '%${search.trim().toLowerCase()}%';
        predicate =
            predicate &
            (t.email.lower().like(term) | t.name.lower().like(term));
      }
      return predicate;
    }

    final rows =
        await (db.select(db.users)
              ..where(filter)
              ..orderBy([
                (t) => OrderingTerm.asc(t.name),
                (t) => OrderingTerm.asc(t.id),
              ])
              ..limit(limit, offset: offset))
            .get();

    final countExpression = db.users.id.count();
    final countQuery = db.selectOnly(db.users)
      ..addColumns([countExpression])
      ..where(filter(db.users));
    final total = (await countQuery.getSingle()).read(countExpression) ?? 0;

    return UserPage(users: await _summarise(rows), total: total);
  }

  /// Batches the role and session lookups across the whole page, so listing
  /// 25 users costs three queries rather than fifty-one.
  Future<List<UserSummary>> _summarise(List<User> users) async {
    if (users.isEmpty) return const [];
    final ids = users.map((u) => u.id).toList(growable: false);

    final roleRows = await (db.select(db.userRoles).join([
      innerJoin(db.roles, db.roles.id.equalsExp(db.userRoles.roleId)),
    ])..where(db.userRoles.userId.isIn(ids))).get();

    final rolesByUser = <String, List<Role>>{};
    for (final row in roleRows) {
      rolesByUser
          .putIfAbsent(row.readTable(db.userRoles).userId, () => [])
          .add(row.readTable(db.roles));
    }

    final now = DateTime.now().toUtc();
    final sessionRows =
        await (db.select(db.sessions)
              ..where((t) => t.userId.isIn(ids))
              ..where((t) => t.revokedAt.isNull())
              ..where((t) => t.refreshExpiresAt.isBiggerThanValue(now)))
            .get();
    final sessionCounts = <String, int>{};
    for (final session in sessionRows) {
      final user = users.firstWhere((u) => u.id == session.userId);
      if (session.epoch != user.sessionEpoch) continue;
      sessionCounts.update(
        session.userId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    return [
      for (final user in users)
        UserSummary(
          user: user,
          roleKeys: [for (final r in rolesByUser[user.id] ?? const []) r.key],
          roleNames: [for (final r in rolesByUser[user.id] ?? const []) r.name],
          activeSessions: sessionCounts[user.id] ?? 0,
        ),
    ];
  }

  Future<UserSummary?> byId(String id) async {
    final user = await (db.select(
      db.users,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (user == null) return null;
    return (await _summarise([user])).first;
  }

  Future<List<Role>> allRoles() =>
      (db.select(db.roles)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  /// Per-user permission overrides, for the detail screen.
  Future<Map<String, bool>> overridesFor(String userId) async {
    final rows = await (db.select(
      db.userPermissions,
    )..where((t) => t.userId.equals(userId))).get();
    return {for (final row in rows) row.permissionKey: row.granted};
  }

  // -------------------------------------------------------------------
  // Invitation (§9)
  // -------------------------------------------------------------------

  /// Creates a pending account and emails a single-use invitation link.
  ///
  /// The account exists immediately — so it shows in the list as *Pending* and
  /// its role is already decided — but it holds no password and cannot
  /// authenticate until the link is claimed.
  Future<({UserMutation result, String? token})> invite({
    required Principal actor,
    required String email,
    required String name,
    required List<String> roleKeys,
    Map<String, bool> permissionOverrides = const {},
    String? phone,
    String? ipAddress,
  }) async {
    final normalised = normaliseEmail(email);
    if (!isPlausibleEmail(normalised)) {
      return (
        result: const UserMutation.failed(UserMutationError.invalidEmail),
        token: null,
      );
    }

    final existing =
        await (db.select(db.users)
              ..where((t) => t.email.equals(normalised))
              ..where((t) => t.deletedAt.isNull()))
            .getSingleOrNull();
    if (existing != null) {
      return (
        result: const UserMutation.failed(UserMutationError.emailInUse),
        token: null,
      );
    }

    final roles = await _resolveRoles(roleKeys);
    if (roles == null) {
      return (
        result: const UserMutation.failed(UserMutationError.invalidRole),
        token: null,
      );
    }
    if (!_permissionsExist(permissionOverrides.keys)) {
      return (
        result: const UserMutation.failed(UserMutationError.invalidPermission),
        token: null,
      );
    }

    final now = DateTime.now().toUtc();
    final id = newId();

    await db.transaction(() async {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: id,
              email: normalised,
              name: name.trim(),
              phone: Value(phone?.trim()),
              status: const Value('pending'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final role in roles) {
        await db
            .into(db.userRoles)
            .insert(
              UserRolesCompanion.insert(
                userId: id,
                roleId: role.id,
                grantedAt: now,
                grantedBy: Value(actor.id),
              ),
            );
      }
      await _writeOverrides(id, permissionOverrides, actor.id, now);
    });

    final token = await tokenStore.issue(
      userId: id,
      purpose: TokenPurpose.invitation,
      validFor: env.invitationTtl,
      createdBy: actor.id,
    );

    // Recorded rather than swallowed. The administrator typed this
    // address; an invitation that never arrives leaves them waiting on
    // somebody who was never told. The account is still created and the
    // link stays valid, so the answer is to send it again — but the
    // audit trail has to say which of those happened.
    final delivered = await notifications.trySendSecurity(
      templates.invitation(
        to: normalised,
        name: name.trim(),
        invitedBy: actor.user.name,
        roleName: roles.map((r) => r.name).join(', '),
        acceptUrl: '${env.appUrl}/#/accept-invitation?token=$token',
        validFor: env.invitationTtl,
      ),
    );

    await audit.record(
      action: AuditAction.userInvited,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: id,
      targetLabel: normalised,
      metadata: {
        'roles': roles.map((r) => r.key).toList(),
        'emailDelivered': delivered,
      },
      ipAddress: ipAddress,
    );

    final created = await (db.select(
      db.users,
    )..where((t) => t.id.equals(id))).getSingle();
    return (result: UserMutation.ok(created), token: token);
  }

  /// Issues a fresh invitation for someone who never claimed the first.
  Future<UserMutation> resendInvitation({
    required Principal actor,
    required String userId,
    String? ipAddress,
  }) async {
    final user =
        await (db.select(db.users)
              ..where((t) => t.id.equals(userId))
              ..where((t) => t.deletedAt.isNull()))
            .getSingleOrNull();
    if (user == null || user.status != 'pending') {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    final token = await tokenStore.issue(
      userId: user.id,
      purpose: TokenPurpose.invitation,
      validFor: env.invitationTtl,
      createdBy: actor.id,
    );
    final roleNames = (await _rolesOf(user.id)).map((r) => r.name).join(', ');

    // Recorded rather than swallowed. The administrator typed this
    // address; an invitation that never arrives leaves them waiting on
    // somebody who was never told. The account is still created and the
    // link stays valid, so the answer is to send it again — but the
    // audit trail has to say which of those happened.
    final delivered = await notifications.trySendSecurity(
      templates.invitation(
        to: user.email,
        name: user.name,
        invitedBy: actor.user.name,
        roleName: roleNames.isEmpty ? 'a member' : roleNames,
        acceptUrl: '${env.appUrl}/#/accept-invitation?token=$token',
        validFor: env.invitationTtl,
      ),
    );
    await audit.record(
      action: AuditAction.userInvited,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: user.id,
      targetLabel: user.email,
      metadata: {'resent': true, 'emailDelivered': delivered},
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  /// Cancels an unclaimed invitation, leaving no account behind.
  Future<UserMutation> revokeInvitation({
    required Principal actor,
    required String userId,
    String? ipAddress,
  }) async {
    final user =
        await (db.select(db.users)
              ..where((t) => t.id.equals(userId))
              ..where((t) => t.deletedAt.isNull()))
            .getSingleOrNull();
    if (user == null || user.status != 'pending') {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    await tokenStore.invalidateOutstanding(
      userId: user.id,
      purpose: TokenPurpose.invitation,
    );
    await _softDelete(user);

    await audit.record(
      action: AuditAction.invitationRevoked,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: user.id,
      targetLabel: user.email,
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  // -------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------

  Future<UserMutation> updateDetails({
    required Principal actor,
    required String userId,
    String? name,
    String? phone,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    await (db.update(db.users)..where((t) => t.id.equals(userId))).write(
      UsersCompanion(
        name: name == null || name.trim().isEmpty
            ? const Value.absent()
            : Value(name.trim()),
        phone: phone == null ? const Value.absent() : Value(phone.trim()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );

    await audit.record(
      action: AuditAction.userUpdated,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      // Which fields changed, never their values.
      metadata: {
        'fields': [if (name != null) 'name', if (phone != null) 'phone'],
      },
      ipAddress: ipAddress,
    );
    return UserMutation.ok((await _live(userId))!);
  }

  /// Replaces a user's roles wholesale.
  Future<UserMutation> setRoles({
    required Principal actor,
    required String userId,
    required List<String> roleKeys,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    final roles = await _resolveRoles(roleKeys);
    if (roles == null) {
      return const UserMutation.failed(UserMutationError.invalidRole);
    }

    // Demoting the last administrator would leave nobody able to grant the
    // role back, so it is refused outright.
    final losingAdmin = !roles.any((r) => r.key == administratorRoleKey);
    if (losingAdmin && await access.isLastActiveAdministrator(userId)) {
      return const UserMutation.failed(UserMutationError.lastAdministrator);
    }

    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.delete(
        db.userRoles,
      )..where((t) => t.userId.equals(userId))).go();
      for (final role in roles) {
        await db
            .into(db.userRoles)
            .insert(
              UserRolesCompanion.insert(
                userId: userId,
                roleId: role.id,
                grantedAt: now,
                grantedBy: Value(actor.id),
              ),
            );
      }
    });

    await audit.record(
      action: AuditAction.rolesChanged,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      metadata: {'roles': roles.map((r) => r.key).toList()},
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  /// Replaces a user's individual permission overrides (§7).
  Future<UserMutation> setPermissionOverrides({
    required Principal actor,
    required String userId,
    required Map<String, bool> overrides,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }
    if (!_permissionsExist(overrides.keys)) {
      return const UserMutation.failed(UserMutationError.invalidPermission);
    }

    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.delete(
        db.userPermissions,
      )..where((t) => t.userId.equals(userId))).go();
      await _writeOverrides(userId, overrides, actor.id, now);
    });

    await audit.record(
      action: AuditAction.permissionsChanged,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      metadata: {
        'granted': [
          for (final e in overrides.entries)
            if (e.value) e.key,
        ],
        'denied': [
          for (final e in overrides.entries)
            if (!e.value) e.key,
        ],
      },
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  /// Enables or disables an account (§8).
  ///
  /// Disabling ends every session immediately rather than waiting for tokens
  /// to expire, which is the whole point of being able to disable someone.
  Future<UserMutation> setEnabled({
    required Principal actor,
    required String userId,
    required bool enabled,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }
    if (!enabled && actor.id == userId) {
      return const UserMutation.failed(UserMutationError.cannotTargetSelf);
    }
    if (!enabled && await access.isLastActiveAdministrator(userId)) {
      return const UserMutation.failed(UserMutationError.lastAdministrator);
    }

    final now = DateTime.now().toUtc();
    await (db.update(db.users)..where((t) => t.id.equals(userId))).write(
      UsersCompanion(
        status: Value(
          enabled
              ? (user.passwordHash == null ? 'pending' : 'active')
              : 'disabled',
        ),
        updatedAt: Value(now),
      ),
    );

    if (!enabled) {
      await sessions.revokeAllFor(userId, reason: 'account_disabled');
    }

    await audit.record(
      action: enabled ? AuditAction.userEnabled : AuditAction.userDisabled,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      ipAddress: ipAddress,
    );

    await notifications.sendSecurity(
      enabled
          ? templates.accountEnabled(to: user.email, name: user.name)
          : templates.accountDisabled(to: user.email, name: user.name),
    );

    return UserMutation.ok((await _live(userId)) ?? user);
  }

  /// Deactivates an account (§8).
  ///
  /// A soft delete: the row stays so the audit trail keeps naming a real
  /// person, but the account disappears from the list, loses its sessions and
  /// frees its address for re-use.
  Future<UserMutation> deactivate({
    required Principal actor,
    required String userId,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }
    if (actor.id == userId) {
      return const UserMutation.failed(UserMutationError.cannotTargetSelf);
    }
    if (await access.isLastActiveAdministrator(userId)) {
      return const UserMutation.failed(UserMutationError.lastAdministrator);
    }

    await _softDelete(user);
    await audit.record(
      action: AuditAction.userDeleted,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  Future<void> _softDelete(User user) async {
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.users)..where((t) => t.id.equals(user.id))).write(
        UsersCompanion(
          deletedAt: Value(now),
          status: const Value('disabled'),
          // Bumping the epoch is belt-and-braces alongside revoking rows: any
          // token minted a microsecond ago is dead too.
          sessionEpoch: Value(user.sessionEpoch + 1),
          updatedAt: Value(now),
        ),
      );
      await sessions.revokeAllFor(user.id, reason: 'account_deleted');
      for (final purpose in [
        TokenPurpose.invitation,
        TokenPurpose.passwordReset,
        TokenPurpose.emailVerification,
        TokenPurpose.emailChange,
      ]) {
        await tokenStore.invalidateOutstanding(
          userId: user.id,
          purpose: purpose,
        );
      }
    });
  }

  /// Lifts a brute-force lockout early (§19).
  Future<UserMutation> unlock({
    required Principal actor,
    required String userId,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    await guard.unlock(userId);
    await audit.record(
      action: AuditAction.userUnlocked,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: userId,
      targetLabel: user.email,
      ipAddress: ipAddress,
    );
    return UserMutation.ok((await _live(userId))!);
  }

  /// Starts a reset on someone else's behalf (§8).
  ///
  /// The administrator never sees or sets the password — they trigger the same
  /// emailed, single-use link the user would have requested themselves. That
  /// keeps "nobody but the user knows their password" true even of admins.
  Future<UserMutation> sendPasswordReset({
    required Principal actor,
    required String userId,
    String? ipAddress,
  }) async {
    final user = await _live(userId);
    if (user == null) {
      return const UserMutation.failed(UserMutationError.notFound);
    }

    final token = await tokenStore.issue(
      userId: user.id,
      purpose: TokenPurpose.passwordReset,
      validFor: env.passwordResetTtl,
      createdBy: actor.id,
    );

    // Sessions end now rather than when the link is used: an admin resetting a
    // password is usually responding to a compromise.
    await sessions.revokeAllFor(user.id, reason: 'admin_password_reset');

    await notifications.sendSecurity(
      templates.passwordResetByAdmin(
        to: user.email,
        name: user.name,
        adminName: actor.user.name,
        resetUrl: '${env.appUrl}/#/reset-password?token=$token',
        validFor: env.passwordResetTtl,
      ),
    );
    await audit.record(
      action: AuditAction.passwordResetByAdmin,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'user',
      targetId: user.id,
      targetLabel: user.email,
      ipAddress: ipAddress,
    );
    return UserMutation.ok(user);
  }

  /// Ends one of another user's sessions (§18).
  Future<bool> revokeSession({
    required Principal actor,
    required String sessionId,
    String? ipAddress,
  }) async {
    final session = await sessions.byId(sessionId);
    if (session == null || session.revokedAt != null) return false;

    await sessions.revoke(sessionId, 'revoked_by_admin');
    final target = await (db.select(
      db.users,
    )..where((t) => t.id.equals(session.userId))).getSingleOrNull();

    await audit.record(
      action: AuditAction.sessionRevoked,
      actorId: actor.id,
      actorEmail: actor.email,
      targetType: 'session',
      targetId: sessionId,
      targetLabel: target?.email,
      metadata: {'device': session.deviceLabel},
      ipAddress: ipAddress,
    );
    return true;
  }

  Future<List<Session>> sessionsOf(String userId) async {
    final user = await _live(userId);
    if (user == null) return const [];
    return sessions.activeFor(userId, user.sessionEpoch);
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  Future<User?> _live(String id) =>
      (db.select(db.users)
            ..where((t) => t.id.equals(id))
            ..where((t) => t.deletedAt.isNull()))
          .getSingleOrNull();

  Future<List<Role>> _rolesOf(String userId) async {
    final rows = await (db.select(db.userRoles).join([
      innerJoin(db.roles, db.roles.id.equalsExp(db.userRoles.roleId)),
    ])..where(db.userRoles.userId.equals(userId))).get();
    return rows.map((r) => r.readTable(db.roles)).toList();
  }

  /// Null when any key does not name a real role, so an unknown role is a
  /// rejected request rather than a user quietly left with no roles at all.
  Future<List<Role>?> _resolveRoles(List<String> keys) async {
    if (keys.isEmpty) return const [];
    final roles = await (db.select(
      db.roles,
    )..where((t) => t.key.isIn(keys))).get();
    if (roles.length != keys.toSet().length) return null;
    return roles;
  }

  bool _permissionsExist(Iterable<String> keys) =>
      keys.every(permissionsByKey.containsKey);

  Future<void> _writeOverrides(
    String userId,
    Map<String, bool> overrides,
    String actorId,
    DateTime now,
  ) async {
    for (final entry in overrides.entries) {
      await db
          .into(db.userPermissions)
          .insert(
            UserPermissionsCompanion.insert(
              userId: userId,
              permissionKey: entry.key,
              granted: Value(entry.value),
              grantedAt: now,
              grantedBy: Value(actorId),
            ),
          );
    }
  }
}

/// Deliberately permissive.
///
/// Real address validity is only ever settled by delivering to it, which the
/// invitation flow does anyway. Anything stricter mostly rejects valid
/// addresses — plus-addressing, new TLDs, non-ASCII local parts.
bool isPlausibleEmail(String value) {
  if (value.length < 3 || value.length > 320) return false;
  final at = value.indexOf('@');
  if (at <= 0 || at != value.lastIndexOf('@')) return false;
  final domain = value.substring(at + 1);
  if (domain.isEmpty || !domain.contains('.')) return false;
  if (value.contains(' ')) return false;
  return true;
}
