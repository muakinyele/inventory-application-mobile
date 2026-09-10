import 'package:drift/drift.dart';

/// Every table in the identity database.
///
/// Ids are application-generated UUIDv4 text rather than serials: they are
/// minted before the insert, so an audit record can name the row it is about
/// without a round trip, and they leak no row counts to anyone who sees one.
///
/// Every timestamp is stored UTC. Ordering that matters is always tie-broken
/// on `id`, because several audit rows are routinely written inside the same
/// microsecond and would otherwise sort non-deterministically.

/// A person who can sign in.
///
/// [passwordHash] is nullable on purpose: an invited user exists, holds a
/// role, and appears in the admin list *before* they have chosen a password.
/// A null hash can never authenticate — [status] is `pending` until they do.
class Users extends Table {
  TextColumn get id => text()();

  /// Stored lowercased and trimmed. Uniqueness is enforced by a unique index
  /// on this column, so two accounts can never share an address regardless of
  /// the casing either was typed in.
  TextColumn get email => text().withLength(max: 320)();

  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get phone => text().withLength(max: 40).nullable()();

  /// Argon2id, in PHC string format. Null until the account is claimed.
  TextColumn get passwordHash => text().nullable()();

  /// `active` | `pending` | `disabled`. Kept as text rather than an enum
  /// index so a value read straight out of the database is self-describing.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  BoolColumn get emailVerified =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get emailVerifiedAt => dateTime().nullable()();

  /// Counts *consecutive* failures; any success resets it to zero.
  IntColumn get failedLoginCount => integer().withDefault(const Constant(0))();

  /// When set and in the future, authentication is refused. Always a finite
  /// timestamp rather than a boolean, so a lockout cannot become permanent —
  /// an attacker cannot lock a colleague out for good by guessing wrongly.
  DateTimeColumn get lockedUntil => dateTime().nullable()();

  DateTimeColumn get lastLoginAt => dateTime().nullable()();

  /// Bumped whenever every existing session must stop working — a password
  /// change, or "log out everywhere". Cheaper and harder to get wrong than
  /// hunting down individual session rows.
  IntColumn get sessionEpoch => integer().withDefault(const Constant(0))();

  /// Soft delete (§8): the row stays so audit history keeps referring to a
  /// real user, but the account can no longer be used or listed.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A named bundle of permissions.
///
/// [isSystem] marks the three roles the app ships with. They can be granted
/// and revoked but not renamed or deleted, so an administrator cannot remove
/// the only path back into the admin screens.
class Roles extends Table {
  TextColumn get id => text()();
  TextColumn get key => text().withLength(max: 64)();
  TextColumn get name => text().withLength(max: 120)();
  TextColumn get description => text().withDefault(const Constant(''))();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The permission catalogue, seeded from `permissions.dart`.
///
/// Held in a table rather than only in code so the admin UI can list and
/// group them, and so a role's grants are real foreign keys.
class Permissions extends Table {
  TextColumn get key => text().withLength(max: 64)();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// Groups the permission in the admin picker, e.g. `inventory`, `users`.
  TextColumn get category => text().withLength(max: 40)();

  @override
  Set<Column> get primaryKey => {key};
}

class UserRoles extends Table {
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get roleId => text().references(Roles, #id)();
  DateTimeColumn get grantedAt => dateTime()();
  TextColumn get grantedBy => text().nullable()();

  @override
  Set<Column> get primaryKey => {userId, roleId};
}

class RolePermissions extends Table {
  TextColumn get roleId => text().references(Roles, #id)();
  TextColumn get permissionKey => text().references(Permissions, #key)();

  @override
  Set<Column> get primaryKey => {roleId, permissionKey};
}

/// A grant or denial applied to one user on top of their roles (§7).
///
/// [granted] false is a genuine denial, not an absent row, so one permission
/// can be withheld from someone who would otherwise inherit it from a role
/// without having to fork the role for one person.
class UserPermissions extends Table {
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get permissionKey => text().references(Permissions, #key)();
  BoolColumn get granted => boolean().withDefault(const Constant(true))();
  DateTimeColumn get grantedAt => dateTime()();
  TextColumn get grantedBy => text().nullable()();

  @override
  Set<Column> get primaryKey => {userId, permissionKey};
}

/// One signed-in device.
///
/// Only hashes are stored. A stolen database backup therefore yields no usable
/// token, and — because the pepper lives in the environment rather than in the
/// table — neither does an offline attack on the hashes alone.
class Sessions extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().references(Users, #id)();

  TextColumn get accessTokenHash => text()();
  TextColumn get refreshTokenHash => text()();
  DateTimeColumn get accessExpiresAt => dateTime()();
  DateTimeColumn get refreshExpiresAt => dateTime()();

  /// The value of `users.session_epoch` when this session was minted. A
  /// session whose epoch is behind the user's is dead on its next request.
  IntColumn get epoch => integer().withDefault(const Constant(0))();

  /// Set when the session is deliberately ended, so "revoked" and "expired"
  /// stay distinguishable in the security screen.
  DateTimeColumn get revokedAt => dateTime().nullable()();
  TextColumn get revokedReason => text().nullable()();

  /// Detects refresh-token replay: a rotated token records its successor, so
  /// a second use of the old token is unambiguous rather than merely stale.
  TextColumn get rotatedToSessionId => text().nullable()();

  /// Coarse, human-readable device description parsed from the User-Agent.
  /// Deliberately not the raw header, to avoid keeping a high-entropy
  /// fingerprint of the user's machine (§17).
  TextColumn get deviceLabel => text().withDefault(const Constant('Unknown'))();
  TextColumn get ipAddress => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastUsedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One-time tokens for invitation, password reset and email verification.
///
/// A single table rather than three, because all three have identical
/// mechanics — hash, expiry, single use — and one implementation is one place
/// to get the security right.
class AuthTokens extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().references(Users, #id)();

  /// `invitation` | `password_reset` | `email_verification` | `email_change`.
  TextColumn get purpose => text().withLength(max: 32)();

  /// SHA-256 of the token plus the pepper. The token itself only ever exists
  /// in the email that carried it.
  TextColumn get tokenHash => text()();

  DateTimeColumn get expiresAt => dateTime()();
  DateTimeColumn get consumedAt => dateTime().nullable()();

  /// For `email_change`, the address being moved to — it is not written onto
  /// the user until the new address has been proven reachable.
  TextColumn get payload => text().nullable()();

  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every authentication attempt, successful or not.
///
/// Separate from [AuditLogs] because it is written on unauthenticated paths
/// and at much higher volume, and because it powers both the lockout check
/// and the "recent activity" list a user sees on their own security page.
class LoginAttempts extends Table {
  TextColumn get id => text()();

  /// Null when the address matched no account. The attempt is still recorded,
  /// so credential-stuffing against unknown addresses remains visible.
  TextColumn get userId => text().nullable()();

  /// Lowercased address as typed. Needed to throttle attempts against an
  /// address that does not exist yet.
  TextColumn get email => text()();

  BoolColumn get succeeded => boolean()();

  /// Why it failed, for the admin view: `bad_password`, `no_account`,
  /// `locked`, `disabled`, `unverified`. Never contains anything supplied by
  /// the client.
  TextColumn get failureReason => text().nullable()();

  TextColumn get ipAddress => text().nullable()();
  TextColumn get deviceLabel => text().nullable()();
  DateTimeColumn get attemptedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The security audit trail (§20).
///
/// Append-only by convention — nothing in the API updates or deletes a row.
/// [actorId] is nullable because some recorded events have no signed-in actor
/// (a password reset completed from an emailed link, say).
class AuditLogs extends Table {
  TextColumn get id => text()();
  TextColumn get actorId => text().nullable()();

  /// Denormalised so the log still reads correctly after the actor is renamed
  /// or soft-deleted. An audit trail that changes retroactively is not one.
  TextColumn get actorEmail => text().nullable()();

  TextColumn get action => text().withLength(max: 64)();

  /// What was acted on, e.g. `user`, `session`, `role`.
  TextColumn get targetType => text().nullable()();
  TextColumn get targetId => text().nullable()();
  TextColumn get targetLabel => text().nullable()();

  /// `success` | `failure`.
  TextColumn get result => text().withDefault(const Constant('success'))();

  /// Small JSON object of non-sensitive detail — which fields changed, never
  /// their values if they are credentials.
  TextColumn get metadata => text().nullable()();

  TextColumn get ipAddress => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-user opt-outs for non-critical mail (§14).
///
/// Only application notifications appear here. Security mail is not
/// represented at all, which is what makes it impossible to switch off.
class NotificationPreferences extends Table {
  TextColumn get userId => text().references(Users, #id)();

  /// e.g. `low_stock`, `reports`, `announcements`.
  TextColumn get channel => text().withLength(max: 40)();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {userId, channel};
}
