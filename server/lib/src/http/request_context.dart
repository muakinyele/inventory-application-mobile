import 'package:shelf/shelf.dart';

import '../rbac/principal.dart';
import 'api_error.dart';

/// Keys under which the middleware stashes values on a request.
abstract final class ContextKeys {
  static const principal = 'stockpile.principal';
  static const clientIp = 'stockpile.clientIp';
}

extension RequestContext on Request {
  /// The authenticated caller, or null on a public route.
  Principal? get principalOrNull =>
      context[ContextKeys.principal] as Principal?;

  /// The caller on a route that has already been through `requireAuth`.
  Principal get principal {
    final value = principalOrNull;
    if (value == null) {
      throw StateError(
        'principal read on a route that is not behind requireAuth',
      );
    }
    return value;
  }

  String? get clientIp => context[ContextKeys.clientIp] as String?;

  String? get userAgent => headers['user-agent'];

  /// Asserts the caller holds [permission] and returns them.
  ///
  /// The per-route form of `requirePermission`. `shelf_router` hands path
  /// parameters to a handler as extra positional arguments, so a middleware
  /// wrapping a `Handler` cannot be used on a parameterised route — this is
  /// called as the first line of the handler instead, and reads as the
  /// precondition it is.
  Principal require(String permission) {
    final caller = principalOrNull;
    if (caller == null) throw ApiError.unauthenticated;
    if (!caller.can(permission)) throw ApiError.forbidden;
    return caller;
  }

  /// The bearer token, if one was presented. The scheme is matched
  /// case-insensitively, as RFC 7235 requires.
  String? get bearerToken {
    final header = headers['authorization'];
    if (header == null) return null;

    final separator = header.indexOf(' ');
    if (separator < 0) return null;
    if (header.substring(0, separator).toLowerCase() != 'bearer') return null;

    final token = header.substring(separator + 1).trim();
    return token.isEmpty ? null : token;
  }
}

/// Works out who the caller is, at the network level.
///
/// `X-Forwarded-For` is only believed when a proxy is genuinely in front
/// (`TRUST_PROXY_HEADERS`). Trusting it unconditionally would let any client
/// set its own apparent IP and walk straight past the per-IP throttle — the
/// header is attacker-controlled unless something upstream overwrites it.
String? resolveClientIp(Request request, {required bool trustProxyHeaders}) {
  if (trustProxyHeaders) {
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null && forwarded.trim().isNotEmpty) {
      // Left-most entry is the original client; the rest are proxies.
      final first = forwarded.split(',').first.trim();
      if (first.isNotEmpty) return first;
    }
    final real = request.headers['x-real-ip'];
    if (real != null && real.trim().isNotEmpty) return real.trim();
  }

  final connection = request.context['shelf.io.connection_info'];
  if (connection == null) return null;
  try {
    // ignore: avoid_dynamic_calls
    return (connection as dynamic).remoteAddress.address as String?;
  } catch (_) {
    return null;
  }
}
