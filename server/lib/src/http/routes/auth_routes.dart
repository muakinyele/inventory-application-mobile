import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../auth/auth_service.dart';
import '../../auth/session_service.dart';
import '../../auth/token_store.dart';
import '../api_error.dart';
import '../middleware.dart';
import '../rate_limiter.dart';
import '../request_context.dart';
import '../serializers.dart';

/// The unauthenticated credential endpoints (§22).
///
/// Everything here is reachable without a token, so every one of them is
/// rate-limited and every one of them is written to give the same answer
/// whether or not the address it was asked about exists.
Router authRoutes({
  required AuthService auth,
  required RateLimiter loginLimiter,
}) {
  final router = Router();

  // ------------------------------------------------------------------
  // POST /auth/login
  // ------------------------------------------------------------------
  router.post('/login', (Request request) async {
    final body = await readJsonBody(request);
    final email = _requiredString(body, 'email');
    final password = _requiredString(body, 'password');

    final outcome = await auth.login(
      email: email,
      password: password,
      ipAddress: request.clientIp,
      userAgent: request.userAgent,
    );

    switch (outcome) {
      case LoginSucceeded(:final principal, :final session):
        // A successful sign-in clears the caller's allowance, so a shared
        // office IP is not pushed toward the limit by ordinary use.
        loginLimiter.reset('login:${request.clientIp ?? 'unknown'}');
        return jsonResponse({
          'user': principalJson(principal),
          'session': sessionTokensJson(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            accessExpiresAt: session.accessExpiresAt,
            refreshExpiresAt: session.refreshExpiresAt,
          ),
        });

      case LoginRejected(:final reason, :final retryAfter):
        throw switch (reason) {
          LoginRejection.invalidCredentials => ApiError.invalidCredentials,
          LoginRejection.accountDisabled => ApiError.accountDisabled,
          LoginRejection.accountPending => ApiError.accountPending,
          LoginRejection.emailUnverified => ApiError.emailUnverified,
          LoginRejection.accountLocked => ApiError.accountLocked(retryAfter),
          LoginRejection.throttled => ApiError.tooManyRequests(retryAfter),
        };
    }
  });

  // ------------------------------------------------------------------
  // POST /auth/refresh
  // ------------------------------------------------------------------
  router.post('/refresh', (Request request) async {
    final body = await readJsonBody(request);
    final refreshToken = _requiredString(body, 'refreshToken');

    final result = await auth.refresh(
      refreshToken: refreshToken,
      ipAddress: request.clientIp,
      userAgent: request.userAgent,
    );

    final session = result.session;
    if (session == null) {
      // Every failure mode looks the same to the client: sign in again. The
      // distinction between expired, revoked and replayed matters to the
      // audit trail, not to the person at the keyboard.
      throw ApiError.sessionExpired;
    }

    return jsonResponse({
      'session': sessionTokensJson(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        accessExpiresAt: session.accessExpiresAt,
        refreshExpiresAt: session.refreshExpiresAt,
      ),
    });
  });

  // ------------------------------------------------------------------
  // POST /auth/forgot-password
  // ------------------------------------------------------------------
  router.post('/forgot-password', (Request request) async {
    final body = await readJsonBody(request);
    final email = _requiredString(body, 'email');

    await auth.requestPasswordReset(email: email, ipAddress: request.clientIp);

    // Always the same response, always 200 (§10, §27). Whether the address
    // exists, is disabled, or has hit its resend cap makes no difference to
    // what the caller sees.
    return jsonResponse({
      'message':
          'If an account exists for this email address, password reset '
          'instructions have been sent.',
    });
  });

  // ------------------------------------------------------------------
  // POST /auth/reset-password
  // ------------------------------------------------------------------
  router.post('/reset-password', (Request request) async {
    final body = await readJsonBody(request);
    final token = _requiredString(body, 'token');
    final password = _requiredString(body, 'password');

    final outcome = await auth.resetPassword(
      token: token,
      newPassword: password,
      ipAddress: request.clientIp,
    );
    _throwOnTokenOutcome(outcome);

    return jsonResponse({
      'message': 'Your password has been changed. You can now sign in with it.',
    });
  });

  // ------------------------------------------------------------------
  // GET /auth/invitation?token=…  — so the accept page can greet by name
  // ------------------------------------------------------------------
  router.get('/invitation', (Request request) async {
    final token = request.url.queryParameters['token'];
    if (token == null || token.isEmpty) throw ApiError.tokenInvalid;

    final result = await auth.inspectInvitation(token);
    if (result.rejection != null) throw _tokenError(result.rejection!);
    final user = result.user;
    if (user == null) throw ApiError.tokenInvalid;

    // Only what the page needs to render. No id, no status, no roles.
    return jsonResponse({'email': user.email, 'name': user.name});
  });

  // ------------------------------------------------------------------
  // POST /auth/accept-invitation
  // ------------------------------------------------------------------
  router.post('/accept-invitation', (Request request) async {
    final body = await readJsonBody(request);
    final token = _requiredString(body, 'token');
    final password = _requiredString(body, 'password');
    final name = body['name'] as String?;

    final outcome = await auth.acceptInvitation(
      token: token,
      password: password,
      name: name,
      ipAddress: request.clientIp,
    );
    _throwOnTokenOutcome(outcome);

    return jsonResponse({
      'message': 'Your account is ready. You can now sign in.',
    });
  });

  // ------------------------------------------------------------------
  // POST /auth/verify-email
  // ------------------------------------------------------------------
  router.post('/verify-email', (Request request) async {
    final body = await readJsonBody(request);
    final token = _requiredString(body, 'token');

    final outcome = await auth.verifyEmail(
      token: token,
      ipAddress: request.clientIp,
    );
    _throwOnTokenOutcome(outcome);

    return jsonResponse({'message': 'Your email address has been confirmed.'});
  });

  // ------------------------------------------------------------------
  // POST /auth/resend-verification
  // ------------------------------------------------------------------
  router.post('/resend-verification', (Request request) async {
    final body = await readJsonBody(request);
    final email = _requiredString(body, 'email');

    await auth.resendVerification(email: email, ipAddress: request.clientIp);

    // Generic, for the same reason as forgot-password.
    return jsonResponse({
      'message':
          'If an account exists for this email address and still needs '
          'confirming, a new link has been sent.',
    });
  });

  return router;
}

/// The authenticated half of `/auth`.
Router authenticatedAuthRoutes({
  required AuthService auth,
  required SessionService sessions,
}) {
  final router = Router();

  router.get('/me', (Request request) async {
    return jsonResponse({'user': principalJson(request.principal)});
  });

  router.post('/logout', (Request request) async {
    await auth.logout(request.principal, ipAddress: request.clientIp);
    return jsonResponse({'message': 'Signed out.'});
  });

  router.post('/logout-all', (Request request) async {
    final body = await readJsonBody(request);
    // Defaults to keeping the current device signed in, which is what the
    // "sign out my other devices" button means.
    final keepCurrent = body['keepCurrent'] as bool? ?? true;

    final revoked = await auth.logoutEverywhere(
      request.principal,
      keepCurrent: keepCurrent,
      ipAddress: request.clientIp,
    );
    return jsonResponse({'revoked': revoked});
  });

  router.post('/change-password', (Request request) async {
    final body = await readJsonBody(request);
    final current = _requiredString(body, 'currentPassword');
    final next = _requiredString(body, 'newPassword');

    final result = await auth.changePassword(
      principal: request.principal,
      currentPassword: current,
      newPassword: next,
      ipAddress: request.clientIp,
    );

    if (result.wrongCurrent) throw ApiError.wrongCurrentPassword;
    if (result.problems.isNotEmpty) {
      throw ApiError.weakPassword(result.problems);
    }

    // The change invalidated every session, including this one, so a fresh
    // pair is issued for the device that made it. Without this the user is
    // bounced to the sign-in screen for doing the right thing, which teaches
    // people not to change their passwords.
    final user = await auth.byId(request.principal.id);
    final issued = await sessions.issue(
      userId: request.principal.id,
      epoch: user!.sessionEpoch,
      userAgent: request.userAgent,
      ipAddress: request.clientIp,
    );

    return jsonResponse({
      'message': 'Your password has been changed.',
      'session': sessionTokensJson(
        accessToken: issued.accessToken,
        refreshToken: issued.refreshToken,
        accessExpiresAt: issued.accessExpiresAt,
        refreshExpiresAt: issued.refreshExpiresAt,
      ),
    });
  });

  return router;
}

String _requiredString(Map<String, Object?> body, String field) {
  final value = body[field];
  if (value is! String || value.trim().isEmpty) {
    throw ApiError.badRequest('"$field" is required.');
  }
  return value;
}

ApiError _tokenError(TokenRejection rejection) => switch (rejection) {
  TokenRejection.expired => ApiError.tokenExpired,
  TokenRejection.alreadyUsed => ApiError.tokenUsed,
  TokenRejection.unknown => ApiError.tokenInvalid,
};

void _throwOnTokenOutcome(TokenOutcome outcome) {
  if (outcome.rejection != null) throw _tokenError(outcome.rejection!);
  if (outcome.problems.isNotEmpty) {
    throw ApiError.weakPassword(outcome.problems);
  }
}
