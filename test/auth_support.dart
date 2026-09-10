import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/state/auth_controller.dart';

/// A stand-in for the identity API.
///
/// Small on purpose: it answers the handful of routes the client actually
/// calls and records what it was asked, so the tests can assert on the
/// client's behaviour — token handling, refresh, error mapping — without a
/// server. The server's own behaviour is covered by `server/test`, against a
/// real database.
class FakeAuthServer {
  FakeAuthServer({
    this.password = 'correct-horse-battery',
    this.permissions = const ['items.view'],
    this.roles = const ['staff'],
  });

  final String password;
  List<String> permissions;
  List<String> roles;

  /// Every request the client made, in order, as "METHOD /path".
  final List<String> calls = [];

  /// Authorization headers seen, so a test can assert the bearer token is
  /// actually attached.
  final List<String?> authHeaders = [];

  /// Every request's full header map, so a test can assert that nothing the
  /// browser forbids is ever set.
  final List<Map<String, String>> sentHeaders = [];

  int accessCounter = 0;
  int refreshCounter = 0;

  /// Tokens the fake still considers live. Rotation retires the old one, which
  /// is what lets a test prove the client stores the replacement.
  final Set<String> liveAccessTokens = {};
  final Set<String> liveRefreshTokens = {};

  /// Flipped to make the next `/auth/session/me` fail as an expired session,
  /// so the retry-after-refresh path can be exercised.
  bool expireNextAccess = false;

  /// When true, refresh fails — the session is genuinely gone.
  bool refreshFails = false;

  /// Set to fail every request as a transport error.
  bool offline = false;

  http.Client client() => MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    authHeaders.add(request.headers['authorization']);
    sentHeaders.add(Map.of(request.headers));

    if (offline) throw http.ClientException('offline', request.url);

    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    switch ('${request.method} ${request.url.path}') {
      case 'POST /auth/login':
        if (body['password'] != password) {
          return _error(
            401,
            'invalid_credentials',
            'Invalid email or password.',
          );
        }
        return _ok({
          'user': _user(body['email'] as String),
          'session': _session(),
        });

      case 'POST /auth/refresh':
        final presented = body['refreshToken'] as String?;
        if (refreshFails || !liveRefreshTokens.contains(presented)) {
          return _error(401, 'session_expired', 'Your session has expired.');
        }
        // Rotation: the presented token stops working immediately.
        liveRefreshTokens.remove(presented);
        return _ok({'session': _session()});

      case 'GET /auth/session/me':
        final token = _bearer(request);
        if (expireNextAccess) {
          expireNextAccess = false;
          return _error(401, 'session_expired', 'Your session has expired.');
        }
        if (token == null || !liveAccessTokens.contains(token)) {
          return _error(401, 'session_expired', 'Your session has expired.');
        }
        return _ok({'user': _user('ada@example.com')});

      case 'POST /auth/session/logout':
        liveAccessTokens.clear();
        liveRefreshTokens.clear();
        return _ok({'message': 'Signed out.'});

      case 'POST /auth/forgot-password':
        return _ok({
          'message':
              'If an account exists for this email address, password reset '
              'instructions have been sent.',
        });

      case 'POST /auth/session/change-password':
        if (body['currentPassword'] != password) {
          return _error(
            422,
            'wrong_current_password',
            'Your current password is not correct.',
          );
        }
        if ((body['newPassword'] as String).length < 10) {
          return _errorWithDetails(
            422,
            'weak_password',
            'That password cannot be used.',
            ['Use at least 10 characters.'],
          );
        }
        return _ok({'message': 'Changed.', 'session': _session()});

      case 'GET /users':
        return _ok({'users': const [], 'total': 0});
    }

    return _error(404, 'not_found', 'Not found.');
  });

  String? _bearer(http.BaseRequest request) {
    final header = request.headers['authorization'];
    if (header == null || !header.toLowerCase().startsWith('bearer ')) {
      return null;
    }
    return header.substring(7);
  }

  Map<String, Object?> _session() {
    final access = 'access-${++accessCounter}';
    final refresh = 'refresh-${++refreshCounter}';
    liveAccessTokens.add(access);
    liveRefreshTokens.add(refresh);
    return {
      'accessToken': access,
      'refreshToken': refresh,
      'accessExpiresAt': DateTime.now()
          .add(const Duration(minutes: 15))
          .toIso8601String(),
      'refreshExpiresAt': DateTime.now()
          .add(const Duration(days: 30))
          .toIso8601String(),
    };
  }

  Map<String, Object?> _user(String email) => {
    'id': 'user-1',
    'email': email,
    'name': 'Ada Lovelace',
    'status': 'active',
    'emailVerified': true,
    'roles': roles,
    'permissions': permissions,
    'sessionId': 'session-1',
    'createdAt': DateTime.now().toIso8601String(),
  };

  http.Response _ok(Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code, String message) =>
      http.Response(
        jsonEncode({
          'error': {'code': code, 'message': message},
        }),
        status,
        headers: {'content-type': 'application/json'},
      );

  http.Response _errorWithDetails(
    int status,
    String code,
    String message,
    List<String> details,
  ) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': message, 'details': details},
    }),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// An [AuthController] wired to [server], storing tokens in memory.
({AuthController auth, InMemoryTokenStorage storage}) newAuth(
  FakeAuthServer server, {
  InMemoryTokenStorage? storage,
}) {
  final store = storage ?? InMemoryTokenStorage();
  return (
    auth: AuthController(
      api: AuthApi(
        baseUrl: 'http://localhost:8080',
        storage: store,
        client: server.client(),
      ),
    ),
    storage: store,
  );
}
