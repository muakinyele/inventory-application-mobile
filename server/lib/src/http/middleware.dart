import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../auth/auth_service.dart';
import '../config/env.dart';
import 'api_error.dart';
import 'rate_limiter.dart';
import 'request_context.dart';

/// Turns anything thrown by a handler into a safe JSON response.
///
/// [ApiError] is passed through as written. Everything else is logged
/// server-side and returned as a bare 500: a client must never see a stack
/// trace, a SQL message or a file path (§24, §27).
Middleware errorHandler({
  required void Function(Object error, StackTrace stackTrace) onError,
}) {
  return (innerHandler) {
    return (request) async {
      try {
        return await innerHandler(request);
      } on ApiError catch (error) {
        return error.toResponse();
      } catch (error, stackTrace) {
        onError(error, stackTrace);
        return ApiError.internal.toResponse();
      }
    };
  };
}

/// Response headers that cost nothing and close off whole classes of attack.
Middleware securityHeaders() {
  return (innerHandler) {
    return (request) async {
      final response = await innerHandler(request);
      return response.change(
        headers: {
          // The API only ever returns JSON, so there is nothing for a browser
          // to sniff into something executable.
          'x-content-type-options': 'nosniff',
          'x-frame-options': 'DENY',
          'referrer-policy': 'no-referrer',
          // No API response should ever sit in a shared cache: they are all
          // either per-user or credential-bearing.
          'cache-control': 'no-store',
          // The API serves no HTML, so everything is denied outright.
          'content-security-policy':
              "default-src 'none'; frame-ancestors 'none'",
        },
      );
    };
  };
}

/// CORS restricted to an explicit allowlist.
///
/// The origin is echoed back only if it is configured, and `*` is never used —
/// a wildcard would let any site on the internet call the API with a token it
/// had somehow obtained.
Middleware cors(List<String> allowedOrigins) {
  return (innerHandler) {
    return (request) async {
      final origin = request.headers['origin'];
      final allowed = origin != null && allowedOrigins.contains(origin);

      final headers = <String, String>{
        if (allowed) ...{
          'access-control-allow-origin': origin,
          'access-control-allow-methods':
              'GET, POST, PATCH, PUT, DELETE, OPTIONS',
          'access-control-allow-headers': 'authorization, content-type',
          'access-control-max-age': '86400',
          // Tells caches the response varies by origin, so one origin's
          // response is never served to another.
          'vary': 'Origin',
        },
      };

      if (request.method == 'OPTIONS') {
        return Response(allowed ? 204 : 403, headers: headers);
      }
      final response = await innerHandler(request);
      return response.change(headers: headers);
    };
  };
}

/// Attaches the resolved client IP to every request.
Middleware clientIp(Env env) {
  return (innerHandler) {
    return (request) {
      final ip = resolveClientIp(
        request,
        trustProxyHeaders: env.trustProxyHeaders,
      );
      return innerHandler(request.change(context: {ContextKeys.clientIp: ip}));
    };
  };
}

/// Resolves a bearer token to a principal, when one is present.
///
/// Deliberately does *not* reject anonymous requests — that is [requireAuth]'s
/// job. Splitting the two lets a route be public while still knowing who the
/// caller is if they happen to be signed in.
Middleware resolvePrincipal(AuthService auth) {
  return (innerHandler) {
    return (request) async {
      final token = request.bearerToken;
      if (token == null) return innerHandler(request);

      final principal = await auth.authenticate(token);
      if (principal == null) return innerHandler(request);

      return innerHandler(
        request.change(context: {ContextKeys.principal: principal}),
      );
    };
  };
}

/// Rejects anonymous callers.
///
/// Distinguishes "no token" from "token that did not resolve", because the
/// client reacts differently: the first sends you to sign in, the second
/// triggers a refresh attempt first.
Middleware requireAuth() {
  return (innerHandler) {
    return (request) {
      if (request.principalOrNull != null) return innerHandler(request);
      throw request.bearerToken == null
          ? ApiError.unauthenticated
          : ApiError.sessionExpired;
    };
  };
}

/// The backend half of RBAC (§6, §25).
///
/// This is the enforcement point. The Flutter client hides controls the user
/// cannot use, but that is only ever presentation — a request that reaches
/// here without the permission is refused whatever the client believed.
Middleware requirePermission(String permission) {
  return (innerHandler) {
    return (request) {
      final principal = request.principalOrNull;
      if (principal == null) throw ApiError.unauthenticated;
      if (!principal.can(permission)) throw ApiError.forbidden;
      return innerHandler(request);
    };
  };
}

/// Applies a [RateLimiter] to a route, keyed by client IP.
Middleware throttle(RateLimiter limiter, {String? bucket}) {
  return (innerHandler) {
    return (request) {
      final ip = request.clientIp ?? 'unknown';
      final result = limiter.hit('${bucket ?? request.url.path}:$ip');
      if (!result.allowed) {
        throw ApiError.tooManyRequests(result.retryAfter);
      }
      return innerHandler(request);
    };
  };
}

/// Caps request bodies.
///
/// An unbounded body is a trivial way to exhaust memory, so there is a cap.
/// The old one was 64 KiB on the reasoning that "nothing this API accepts is
/// large", and that was simply not true of this app:
///
///   * an ITEM CARRIES ITS PHOTO INLINE as base64, and so does the company
///     logo on the settings screen. Both are capped at 5 MB by the client and
///     both were refused by the server at 64 KiB — so neither feature worked
///     at all, and the nginx in front was configured to 8m for exactly these;
///   * a RESTORE carries the entire workspace, every row and every photo, in
///     one request.
///
/// THE DEFAULT STAYS TIGHT. Raising it everywhere would make an
/// eight-megabyte password a legitimate request, and refusing that before it
/// is read is the reason this exists. Only the routes that carry an image, and
/// the one that carries the whole workspace, are raised.
Middleware limitBodySize({
  int maxBytes = 64 * 1024,
  Map<String, int> overrides = const {
    // Every row and every photo, in one request.
    '/inventory/restore': 256 * 1024 * 1024,
    // An item carries its photo inline; the client caps the image at 5 MB and
    // base64 inflates it by about a third.
    '/inventory/items': 8 * 1024 * 1024,
    // The company logo lives in preferences, the same way.
    '/inventory/preferences': 8 * 1024 * 1024,
  },
}) {
  return (innerHandler) {
    return (request) async {
      // Leading slash normalised: shelf strips it from `url.path`, and a
      // route table that silently never matches is worse than no table.
      final path = '/${request.url.path}';

      // By PREFIX, because an item is edited at `/inventory/items/<id>`, and
      // longest match wins so a shorter entry cannot shadow a longer one.
      var limit = maxBytes;
      var matched = 0;
      for (final entry in overrides.entries) {
        if (path == entry.key || path.startsWith('${entry.key}/')) {
          if (entry.key.length > matched) {
            matched = entry.key.length;
            limit = entry.value;
          }
        }
      }

      final declared = request.contentLength;
      if (declared != null && declared > limit) {
        throw const ApiError(
          413,
          'payload_too_large',
          'That request is too large.',
        );
      }
      return innerHandler(request);
    };
  };
}

/// Reads and validates a JSON object body.
///
/// Returns an empty map for an empty body so handlers with only optional
/// fields do not each need a null check.
Future<Map<String, Object?>> readJsonBody(Request request) async {
  final body = await request.readAsString();
  if (body.trim().isEmpty) return {};
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw ApiError.badRequest('Expected a JSON object.');
    }
    return decoded;
  } on FormatException {
    throw ApiError.badRequest('Expected valid JSON.');
  }
}

/// JSON response helper.
Response jsonResponse(Object? body, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
