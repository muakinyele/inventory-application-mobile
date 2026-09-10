import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'audit/audit_service.dart';
import 'auth/auth_service.dart';
import 'auth/login_guard.dart';
import 'auth/password_policy.dart';
import 'auth/passwords.dart';
import 'auth/session_service.dart';
import 'auth/token_store.dart';
import 'auth/tokens.dart';
import 'config/env.dart';
import 'db/database.dart';
import 'email/mailer.dart';
import 'email/notification_service.dart';
import 'email/templates.dart';
import 'http/api_error.dart';
import 'http/middleware.dart';
import 'http/rate_limiter.dart';
import 'http/routes/account_routes.dart';
import 'http/routes/audit_routes.dart';
import 'http/routes/auth_routes.dart';
import 'http/routes/user_routes.dart';
import 'rbac/access_service.dart';
import 'users/account_service.dart';
import 'users/user_service.dart';

/// Everything the API needs, constructed once.
///
/// Assembled by hand rather than through a container: there are a dozen
/// objects and the wiring is the clearest documentation of what depends on
/// what.
class Api {
  Api._({
    required this.env,
    required this.db,
    required this.auth,
    required this.users,
    required this.account,
    required this.audit,
    required this.sessions,
    required this.tokenStore,
    required this.guard,
    required this.handler,
  });

  final Env env;
  final AuthDatabase db;
  final AuthService auth;
  final UserService users;
  final AccountService account;
  final AuditService audit;
  final SessionService sessions;
  final TokenStore tokenStore;
  final LoginGuard guard;

  /// The fully wrapped handler, ready for `shelf_io.serve`.
  final Handler handler;

  static Api build({
    required Env env,
    required AuthDatabase db,
    required Mailer mailer,
    required void Function(Object error, StackTrace stackTrace) onError,
    PasswordHasher? hasher,
  }) {
    final tokens = TokenService(env.tokenPepper);
    final passwordHasher = hasher ?? PasswordHasher();
    const policy = PasswordPolicy();

    final templates = EmailTemplates(appName: env.appName, appUrl: env.appUrl);
    // Mail failures are logged, never surfaced: an SMTP outage must not turn
    // "if an account exists…" into a 500 that says one does.
    final safeMailer = FailSafeMailer(mailer, onError: onError);
    final notifications = NotificationService(db: db, mailer: safeMailer);

    final auditService = AuditService(db, onError: onError);
    final access = AccessService(db);
    final tokenStore = TokenStore(db: db, tokens: tokens);
    final sessions = SessionService(
      db: db,
      tokens: tokens,
      accessTtl: env.accessTokenTtl,
      refreshTtl: env.refreshTokenTtl,
    );
    final guard = LoginGuard(
      db: db,
      maxFailedLogins: env.maxFailedLogins,
      lockoutDuration: env.lockoutDuration,
    );

    final auth = AuthService(
      db: db,
      env: env,
      hasher: passwordHasher,
      policy: policy,
      tokenStore: tokenStore,
      sessions: sessions,
      access: access,
      guard: guard,
      audit: auditService,
      notifications: notifications,
      templates: templates,
    );

    final users = UserService(
      db: db,
      env: env,
      access: access,
      audit: auditService,
      tokenStore: tokenStore,
      sessions: sessions,
      guard: guard,
      notifications: notifications,
      templates: templates,
      hasher: passwordHasher,
    );

    final account = AccountService(
      db: db,
      env: env,
      audit: auditService,
      tokenStore: tokenStore,
      sessions: sessions,
      guard: guard,
      notifications: notifications,
      templates: templates,
      hasher: passwordHasher,
    );

    // Two separate budgets. Sign-in attempts are far more common than
    // password-reset requests, and a shared limit would let one drain the
    // other.
    // Set well above normal use: a whole office shares one NAT address, and
    // throttling the building is worse than the attack. This is only a coarse
    // flood guard — the real brute-force protection is `LoginGuard`, which is
    // per-account, database-backed, and therefore shared across instances.
    final loginLimiter = RateLimiter(
      limit: 60,
      window: const Duration(minutes: 5),
    );
    final emailLimiter = RateLimiter(
      limit: 5,
      window: const Duration(minutes: 15),
    );

    final router = Router();

    // ---- Public -----------------------------------------------------
    router.get('/health', (Request request) async {
      // Deliberately says nothing about version, database or configuration.
      // A health endpoint is the most-scanned URL on any deployment.
      return jsonResponse({'status': 'ok'});
    });

    // Mount order matters: `shelf_router` takes the first prefix that matches,
    // so the more specific `/auth/session` and `/account/public` have to be
    // registered before the prefixes that would otherwise swallow them.

    router.mount(
      '/auth/session',
      Pipeline()
          .addMiddleware(requireAuth())
          .addHandler(
            authenticatedAuthRoutes(auth: auth, sessions: sessions).call,
          ),
    );

    router.mount(
      '/auth',
      Pipeline()
          .addMiddleware(throttle(loginLimiter, bucket: 'auth'))
          .addHandler(authRoutes(auth: auth, loginLimiter: loginLimiter).call),
    );

    // The mail-heavy endpoints get the tighter budget.
    router.mount(
      '/account/public',
      Pipeline()
          .addMiddleware(throttle(emailLimiter, bucket: 'account-public'))
          .addHandler(publicAccountRoutes(account: account).call),
    );

    router.mount(
      '/account',
      Pipeline()
          .addMiddleware(requireAuth())
          .addHandler(accountRoutes(account: account).call),
    );

    router.mount(
      '/users',
      Pipeline()
          .addMiddleware(requireAuth())
          .addHandler(userRoutes(users: users).call),
    );

    router.mount(
      '/audit-logs',
      Pipeline()
          .addMiddleware(requireAuth())
          .addHandler(auditRoutes(audit: auditService).call),
    );

    router.all(
      '/<ignored|.*>',
      (Request request) => ApiError.notFound.toResponse(),
    );

    // Order matters, and one part of it is load-bearing: **`cors` must sit
    // outside `errorHandler`**.
    //
    // A handler reports failure by *throwing* an `ApiError`, which unwinds
    // past every middleware until `errorHandler` turns it into a response. If
    // `cors` were outside, its `response.change(headers: ...)` would already
    // have been skipped on the way up, so no error response would carry
    // `Access-Control-Allow-Origin` — and a browser would refuse to read any
    // of them. Every 401, 403 and 422 would surface in the app as an opaque
    // "could not reach the server" instead of "Invalid email or password",
    // while 200s worked fine. The same reasoning applies to
    // `securityHeaders`.
    final handler = Pipeline()
        .addMiddleware(securityHeaders())
        .addMiddleware(cors(env.corsOrigins))
        .addMiddleware(errorHandler(onError: onError))
        .addMiddleware(limitBodySize())
        .addMiddleware(clientIp(env))
        .addMiddleware(resolvePrincipal(auth))
        .addHandler(router.call);

    return Api._(
      env: env,
      db: db,
      auth: auth,
      users: users,
      account: account,
      audit: auditService,
      sessions: sessions,
      tokenStore: tokenStore,
      guard: guard,
      handler: handler,
    );
  }

  /// Housekeeping the server runs on a timer: expired sessions and tokens go,
  /// and the attempt log is trimmed so it cannot grow without bound.
  Future<void> sweep() async {
    await sessions.purgeExpired();
    await tokenStore.purgeExpired();
    await guard.purgeOlderThan(const Duration(days: 90));
  }
}
