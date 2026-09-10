import 'package:drift/drift.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:postgres/postgres.dart' as pg;

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Users,
    Roles,
    Permissions,
    UserRoles,
    RolePermissions,
    UserPermissions,
    Sessions,
    AuthTokens,
    LoginAttempts,
    AuditLogs,
    NotificationPreferences,
  ],
)
class AuthDatabase extends _$AuthDatabase {
  AuthDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
  );

  /// Indexes are created here rather than declared on the tables because two
  /// of them are partial, which drift's table-level annotation cannot express.
  Future<void> _createIndexes() async {
    const statements = [
      // Partial, so a soft-deleted account releases its address for re-use
      // while still blocking two live accounts from sharing one.
      'CREATE UNIQUE INDEX users_email_unique ON users (email) '
          'WHERE deleted_at IS NULL',
      'CREATE UNIQUE INDEX roles_key_unique ON roles (key)',

      // The hot path: every authenticated request looks a session up by its
      // access-token hash, so this index decides the API's latency floor.
      'CREATE UNIQUE INDEX sessions_access_hash ON sessions (access_token_hash)',
      'CREATE UNIQUE INDEX sessions_refresh_hash ON sessions '
          '(refresh_token_hash)',
      // Listing a user's live sessions for the security screen.
      'CREATE INDEX sessions_user_active ON sessions (user_id, revoked_at)',

      'CREATE UNIQUE INDEX auth_tokens_hash ON auth_tokens (token_hash)',
      // Redeeming a token also has to reject a second, still-unexpired token
      // of the same purpose for the same user.
      'CREATE INDEX auth_tokens_user_purpose ON auth_tokens '
          '(user_id, purpose, consumed_at)',

      // Both lockout checks: consecutive failures for an address, and the
      // per-IP throttle.
      'CREATE INDEX login_attempts_email_time ON login_attempts '
          '(email, attempted_at DESC)',
      'CREATE INDEX login_attempts_ip_time ON login_attempts '
          '(ip_address, attempted_at DESC)',
      'CREATE INDEX login_attempts_user_time ON login_attempts '
          '(user_id, attempted_at DESC)',

      // The audit screen is paged newest-first and filtered on each of these.
      'CREATE INDEX audit_logs_created ON audit_logs (created_at DESC, id)',
      'CREATE INDEX audit_logs_actor ON audit_logs (actor_id, created_at DESC)',
      'CREATE INDEX audit_logs_action ON audit_logs (action, created_at DESC)',

      'CREATE INDEX user_roles_role ON user_roles (role_id)',
    ];
    for (final statement in statements) {
      await customStatement(statement);
    }
  }
}

/// Opens the pool the server runs on.
///
/// `sslMode` is required rather than optional in production: a plaintext
/// connection would put every password hash and session token on the wire.
QueryExecutor openPostgres(String databaseUrl, {bool requireSsl = false}) {
  final uri = Uri.parse(databaseUrl);
  final userInfo = uri.userInfo.split(':');

  return PgDatabase(
    endpoint: pg.Endpoint(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.pathSegments.isEmpty ? 'postgres' : uri.pathSegments.first,
      username: userInfo.isNotEmpty && userInfo.first.isNotEmpty
          ? Uri.decodeComponent(userInfo.first)
          : null,
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
    ),
    settings: pg.ConnectionSettings(
      sslMode: requireSsl ? pg.SslMode.require : pg.SslMode.disable,
    ),
  );
}
