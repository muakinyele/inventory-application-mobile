import 'dart:convert';

import 'package:shelf/shelf.dart';

/// A failure the client is allowed to know about.
///
/// Every error the API returns is one of these. Anything else — a dropped
/// connection, a constraint violation, a bug — is caught by the error
/// middleware and becomes a flat 500 with no detail, so a stack trace or a
/// database message can never reach a user (§24, §27).
class ApiError implements Exception {
  const ApiError(
    this.statusCode,
    this.code,
    this.message, {
    this.details,
    this.retryAfter,
  });

  final int statusCode;

  /// A stable machine-readable code. The client switches on this; the
  /// [message] is what it shows if it has nothing better.
  final String code;

  /// Already phrased for a human. Never contains internals.
  final String message;

  /// Field-level problems, e.g. password policy failures.
  final List<String>? details;

  final Duration? retryAfter;

  Response toResponse() {
    return Response(
      statusCode,
      body: jsonEncode({
        'error': {
          'code': code,
          'message': message,
          if (details != null && details!.isNotEmpty) 'details': details,
        },
      }),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        if (retryAfter != null)
          'retry-after': '${retryAfter!.inSeconds.clamp(1, 86400)}',
      },
    );
  }

  // -----------------------------------------------------------------
  // The catalogue. Wording comes straight from §27.
  // -----------------------------------------------------------------

  /// Deliberately identical for "no such account" and "wrong password", so
  /// the endpoint cannot be used to discover which addresses are registered.
  static const invalidCredentials = ApiError(
    401,
    'invalid_credentials',
    'Invalid email or password.',
  );

  static const accountDisabled = ApiError(
    403,
    'account_disabled',
    'Your account has been disabled. Please contact an administrator.',
  );

  static const accountPending = ApiError(
    403,
    'account_pending',
    'This account has not been activated yet. Check your email for an '
        'invitation link, or ask an administrator to resend it.',
  );

  static const emailUnverified = ApiError(
    403,
    'email_unverified',
    'Please confirm your email address before signing in. We can send you a '
        'new confirmation link.',
  );

  static ApiError accountLocked(Duration? retryAfter) => ApiError(
    429,
    'account_locked',
    'Too many sign-in attempts. Your account is locked for a short while — '
        'try again later, or reset your password to get back in now.',
    retryAfter: retryAfter,
  );

  static ApiError tooManyRequests(Duration? retryAfter) => ApiError(
    429,
    'too_many_requests',
    'Too many attempts. Please wait a moment and try again.',
    retryAfter: retryAfter,
  );

  static const sessionExpired = ApiError(
    401,
    'session_expired',
    'Your session has expired. Please sign in again.',
  );

  static const unauthenticated = ApiError(
    401,
    'unauthenticated',
    'Please sign in to continue.',
  );

  static const forbidden = ApiError(
    403,
    'forbidden',
    'You do not have permission to do that.',
  );

  static const tokenExpired = ApiError(
    400,
    'token_expired',
    'This link has expired. Please request a new one.',
  );

  static const tokenUsed = ApiError(
    400,
    'token_used',
    'This link has already been used. Please request a new one.',
  );

  static const tokenInvalid = ApiError(
    400,
    'token_invalid',
    'This link is not valid. Please request a new one.',
  );

  static ApiError weakPassword(List<String> problems) => ApiError(
    422,
    'weak_password',
    'That password cannot be used.',
    details: problems,
  );

  static const wrongCurrentPassword = ApiError(
    422,
    'wrong_current_password',
    'Your current password is not correct.',
  );

  static const emailInUse = ApiError(
    409,
    'email_in_use',
    'That email address is already in use.',
  );

  static const invalidEmail = ApiError(
    422,
    'invalid_email',
    'Enter a valid email address.',
  );

  static const notFound = ApiError(404, 'not_found', 'Not found.');

  static ApiError badRequest(String message, {List<String>? details}) =>
      ApiError(400, 'bad_request', message, details: details);

  static const lastAdministrator = ApiError(
    409,
    'last_administrator',
    'This is the only administrator. Give someone else the Administrator role '
        'first.',
  );

  static const cannotTargetSelf = ApiError(
    409,
    'cannot_target_self',
    'You cannot do that to your own account.',
  );

  static const internal = ApiError(
    500,
    'internal_error',
    'Something went wrong. Please try again.',
  );
}
