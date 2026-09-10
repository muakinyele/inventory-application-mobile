import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:stockpile_server/src/api.dart';
import 'package:stockpile_server/src/auth/passwords.dart';
import 'package:stockpile_server/src/auth/tokens.dart';
import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';
import 'package:stockpile_server/src/email/mailer.dart';
import 'package:stockpile_server/src/rbac/permissions.dart';
import 'package:drift/drift.dart';

/// Where the tests expect PostgreSQL.
///
/// Overridable so CI can point at its own instance without editing code.
String get testDatabaseUrl =>
    Platform.environment['TEST_DATABASE_URL'] ??
    'postgres://${Platform.environment['USER'] ?? 'postgres'}'
        '@localhost:5432/stockpile_auth_test';

/// A running API with a real database and a mailbox you can read.
///
/// Tests exercise the stack through [request], the same handler `bin/server`
/// serves — so middleware, routing, permission checks and error shaping are
/// all covered rather than stubbed. Only the SMTP transport is substituted.
class TestServer {
  TestServer._({
    required this.api,
    required this.db,
    required this.mailer,
    required this.env,
  });

  final Api api;
  final AuthDatabase db;
  final InMemoryMailer mailer;
  final Env env;

  static Future<TestServer> start({
    Map<String, String> config = const {},
  }) async {
    final env = Env.load(
      // A path that will not exist, so a developer's own `server/.env` can
      // never leak into a test run and change its behaviour.
      envFile: '.env.test.absent',
      overrides: {
        'APP_ENV': 'test',
        'DATABASE_URL': testDatabaseUrl,
        'APP_URL': 'http://localhost:8080',
        'TOKEN_PEPPER': 'test-pepper-that-is-at-least-32-characters-long',
        'MAX_FAILED_LOGINS': '3',
        'LOCKOUT_MINUTES': '15',
        ...config,
      },
    );

    final db = AuthDatabase(openPostgres(env.databaseUrl));
    await _reset(db);
    await Bootstrap(db).run();

    final mailer = InMemoryMailer();
    final api = Api.build(
      env: env,
      db: db,
      mailer: mailer,
      onError: (error, stackTrace) {
        // Surfaced rather than swallowed: an unexpected 500 during a test is
        // a failure, and silent logging would hide it.
        stderr.writeln('unexpected server error: $error\n$stackTrace');
      },
      // Argon2id at production settings takes ~50ms a hash, which would make
      // this suite take minutes. The algorithm is unchanged; only its cost is.
      hasher: PasswordHasher(memoryKib: 256, iterations: 1, parallelism: 1),
    );

    return TestServer._(api: api, db: db, mailer: mailer, env: env);
  }

  /// Drops every row so each test starts from a known state.
  ///
  /// `TRUNCATE ... CASCADE` rather than dropping the schema, so the migration
  /// runs once per suite instead of once per test.
  static Future<void> _reset(AuthDatabase db) async {
    await db.customStatement('select 1');
    const tables = [
      'audit_logs',
      'login_attempts',
      'auth_tokens',
      'sessions',
      'notification_preferences',
      'user_permissions',
      'user_roles',
      'role_permissions',
      'permissions',
      'roles',
      'users',
    ];
    for (final table in tables) {
      await db.customStatement('TRUNCATE TABLE $table CASCADE');
    }
  }

  Future<void> close() async => db.close();

  // ------------------------------------------------------------------
  // Making requests
  // ------------------------------------------------------------------

  Future<ApiResponse> request(
    String method,
    String path, {
    Object? body,
    String? accessToken,
    String userAgent = 'Stockpile/1.0 (Test)',
    String ip = '203.0.113.10',
  }) async {
    final response = await api.handler(
      Request(
        method,
        Uri.parse('http://localhost:8080$path'),
        headers: {
          'content-type': 'application/json',
          'user-agent': userAgent,
          // The API only trusts this when TRUST_PROXY_HEADERS is on, which it
          // is not here — so tests share one IP unless they set their own.
          'x-forwarded-for': ip,
          if (accessToken != null) 'authorization': 'Bearer $accessToken',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );

    final text = await response.readAsString();
    return ApiResponse(
      statusCode: response.statusCode,
      body: text.isEmpty ? const {} : jsonDecode(text) as Map<String, Object?>,
      headers: response.headers,
    );
  }

  Future<ApiResponse> post(String path, {Object? body, String? accessToken}) =>
      request('POST', path, body: body, accessToken: accessToken);

  Future<ApiResponse> get(String path, {String? accessToken}) =>
      request('GET', path, accessToken: accessToken);

  Future<ApiResponse> patch(String path, {Object? body, String? accessToken}) =>
      request('PATCH', path, body: body, accessToken: accessToken);

  Future<ApiResponse> delete(String path, {String? accessToken}) =>
      request('DELETE', path, accessToken: accessToken);

  // ------------------------------------------------------------------
  // Fixtures
  // ------------------------------------------------------------------

  /// Creates an active, verified user with a password, bypassing the
  /// invitation flow — most tests are about something else.
  Future<TestUser> createUser({
    required String email,
    String name = 'Test User',
    String password = 'correct-horse-battery',
    String role = staffRoleKey,
    String status = 'active',
    bool emailVerified = true,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final hasher = PasswordHasher(
      memoryKib: 256,
      iterations: 1,
      parallelism: 1,
    );

    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: id,
            email: email.toLowerCase(),
            name: name,
            passwordHash: Value(await hasher.hash(password)),
            status: Value(status),
            emailVerified: Value(emailVerified),
            emailVerifiedAt: Value(emailVerified ? now : null),
            createdAt: now,
            updatedAt: now,
          ),
        );

    final roleRow = await (db.select(
      db.roles,
    )..where((t) => t.key.equals(role))).getSingle();
    await db
        .into(db.userRoles)
        .insert(
          UserRolesCompanion.insert(
            userId: id,
            roleId: roleRow.id,
            grantedAt: now,
          ),
        );

    return TestUser(id: id, email: email.toLowerCase(), password: password);
  }

  /// Signs a user in and returns their tokens.
  Future<TestSession> signIn(
    TestUser user, {
    String ip = '203.0.113.10',
  }) async {
    final response = await request(
      'POST',
      '/auth/login',
      body: {'email': user.email, 'password': user.password},
      ip: ip,
    );
    if (response.statusCode != 200) {
      throw StateError(
        'sign-in failed for ${user.email}: '
        '${response.statusCode} ${response.body}',
      );
    }
    final session = response.body['session']! as Map<String, Object?>;
    return TestSession(
      accessToken: session['accessToken']! as String,
      refreshToken: session['refreshToken']! as String,
      user: user,
    );
  }

  /// Creates a user and signs them in, the two-line setup most tests want.
  Future<TestSession> signedInUser({
    required String email,
    String role = staffRoleKey,
    String password = 'correct-horse-battery',
  }) async {
    final user = await createUser(email: email, role: role, password: password);
    return signIn(user);
  }

  /// The single-use token out of the most recent mail to [address].
  ///
  /// Reads it from the link, which is how a real recipient gets it — so the
  /// tests exercise the same value the email actually carries.
  String? tokenFromMailTo(String address) {
    final message = mailer.lastTo(address);
    if (message == null) return null;
    final match = RegExp(r'token=([A-Za-z0-9_\-]+)').firstMatch(message.text);
    return match?.group(1);
  }

  Future<void> expireTokensFor(String userId, String purpose) async {
    await (db.update(db.authTokens)
          ..where((t) => t.userId.equals(userId))
          ..where((t) => t.purpose.equals(purpose)))
        .write(
          AuthTokensCompanion(
            expiresAt: Value(
              DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            ),
          ),
        );
  }

  /// Ages a session's access token so the next request sees it as expired.
  Future<void> expireAccessToken(String sessionId) async {
    await (db.update(db.sessions)..where((t) => t.id.equals(sessionId))).write(
      SessionsCompanion(
        accessExpiresAt: Value(
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ),
      ),
    );
  }

  /// The raw user row, for assertions about state the API does not expose —
  /// the failure counter and the lockout stamp.
  Future<User> userRow(String id) =>
      (db.select(db.users)..where((t) => t.id.equals(id))).getSingle();

  Future<List<AuditLog>> auditEntries({String? action}) {
    final query = db.select(db.auditLogs)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (action != null) query.where((t) => t.action.equals(action));
    return query.get();
  }
}

class ApiResponse {
  const ApiResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Map<String, String> headers;

  /// The machine-readable error code, when the response is an error.
  String? get errorCode {
    final error = body['error'];
    if (error is! Map) return null;
    return error['code'] as String?;
  }

  String? get errorMessage {
    final error = body['error'];
    if (error is! Map) return null;
    return error['message'] as String?;
  }

  Map<String, Object?> get user => body['user']! as Map<String, Object?>;

  String get accessToken =>
      (body['session']! as Map<String, Object?>)['accessToken']! as String;

  String get refreshToken =>
      (body['session']! as Map<String, Object?>)['refreshToken']! as String;

  @override
  String toString() => '$statusCode $body';
}

class TestUser {
  const TestUser({
    required this.id,
    required this.email,
    required this.password,
  });
  final String id;
  final String email;
  final String password;
}

class TestSession {
  const TestSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });
  final String accessToken;
  final String refreshToken;
  final TestUser user;
}
