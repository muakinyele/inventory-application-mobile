import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/auth_user.dart';
import 'token_storage.dart';

/// An error the API reported, already phrased for a person.
///
/// The server never returns internals, so [message] can be shown as-is. The
/// [code] is what the UI branches on — "resend the verification link" is only
/// offered when the server actually said `email_unverified`.
class AuthApiException implements Exception {
  const AuthApiException({
    required this.code,
    required this.message,
    this.details = const [],
    this.statusCode,
  });

  final String code;
  final String message;

  /// Field-level problems, chiefly password-policy failures.
  final List<String> details;

  final int? statusCode;

  /// The client could not reach the server at all.
  bool get isNetworkError => code == 'network_error';

  /// The session is gone and the user must sign in again.
  bool get isAuthExpired =>
      code == 'session_expired' || code == 'unauthenticated';

  @override
  String toString() => message;
}

/// The client's half of §22.
///
/// One place that knows the API's URLs and shapes, so no widget builds a
/// request. It also owns token refresh: [_send] retries once on a 401 after
/// renewing, which is what lets a 15-minute access token be invisible to the
/// rest of the app.
class AuthApi {
  AuthApi({required this.baseUrl, required this.storage, http.Client? client})
    : _client = client ?? http.Client();

  /// Where the identity API lives. Compile-time so a release build cannot be
  /// pointed somewhere else by editing a file on disk:
  ///
  ///     flutter build web --dart-define=STOCKPILE_API_URL=https://api.example
  static const String defaultBaseUrl = String.fromEnvironment(
    'STOCKPILE_API_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// Turns a path into the URL to call.
  ///
  /// A **relative** base — `/api`, which is what the container image is built
  /// with — is resolved against the page the app was served from. That means
  /// one web image works in development, staging and production without
  /// rebuilding, and the API is same-origin behind the reverse proxy, so CORS
  /// stops being involved at all.
  ///
  /// An **absolute** base is used unchanged, which is what the Android and
  /// iOS builds need: there is no page origin to resolve against.
  Uri endpointFor(String path) {
    final target = '$baseUrl$path';
    final parsed = Uri.parse(target);
    return parsed.hasScheme ? parsed : Uri.base.resolve(target);
  }

  final String baseUrl;
  final TokenStorage storage;
  final http.Client _client;

  /// Called when refresh fails, so the controller can drop to signed-out
  /// without every call site having to handle it.
  void Function()? onSessionLost;

  StoredTokens? _tokens;
  StoredTokens? get tokens => _tokens;

  /// Guards against a burst of parallel requests each firing its own refresh.
  /// The first one does the work; the rest await the same future.
  Future<StoredTokens?>? _inFlightRefresh;

  Future<void> restore() async => _tokens = await storage.read();

  Future<void> _persist(StoredTokens tokens, {required bool remember}) async {
    _tokens = tokens;
    if (remember) {
      await storage.write(tokens);
    } else {
      // "Remember me" off: the session lives for this run only, so a shared
      // machine does not keep it after the app is closed.
      await storage.clear();
    }
  }

  Future<void> forget() async {
    _tokens = null;
    await storage.clear();
  }

  // -------------------------------------------------------------------
  // Transport
  // -------------------------------------------------------------------

  /// An authenticated request against this session, for callers outside this
  /// file.
  ///
  /// Exposed so the inventory client shares one token pipeline — proactive
  /// refresh, the 401 retry, and revocation — rather than growing a second
  /// copy that drifts out of step with this one. The path is relative to
  /// [baseUrl], the same as every method here.
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
  }) => _send(method, path, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool allowRetry = true,
  }) async {
    if (authenticated) {
      // Refresh proactively when the token is known to be stale: cheaper than
      // a round trip that is certain to 401.
      final current = _tokens;
      if (current != null && current.accessExpired) {
        await _refresh();
      }
    }

    final http.Response response;
    try {
      response = await _client
          .send(_request(method, path, body, authenticated))
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const AuthApiException(
        code: 'network_error',
        message: 'The server took too long to respond. Please try again.',
      );
    } catch (_) {
      // Deliberately not catching SocketException by type: `dart:io` does not
      // exist on the web, and importing it would break that build entirely.
      // On the web `http` throws ClientException instead, so both platforms
      // are covered by treating any transport failure the same way.
      throw const AuthApiException(
        code: 'network_error',
        message: 'Could not reach the server. Check your connection.',
      );
    }

    if (response.statusCode == 401 && authenticated && allowRetry) {
      final renewed = await _refresh();
      if (renewed != null) {
        return _send(method, path, body: body, allowRetry: false);
      }
    }

    return _decode(response);
  }

  http.BaseRequest _request(
    String method,
    String path,
    Object? body,
    bool authenticated,
  ) {
    final request = http.Request(method, endpointFor(path));
    request.headers['content-type'] = 'application/json; charset=utf-8';
    _identify(request.headers);

    final token = _tokens?.accessToken;
    if (authenticated && token != null) {
      request.headers['authorization'] = 'Bearer $token';
    }
    if (body != null) request.body = jsonEncode(body);
    return request;
  }

  /// Identifies the app to the server, so the security screen can say
  /// "Stockpile app (Android)" rather than guessing from a browser string.
  ///
  /// **Never set on the web.** `User-Agent` is a forbidden header name there:
  /// the browser refuses the request outright rather than dropping the header,
  /// which made every call fail as a transport error. The browser sends its
  /// own User-Agent regardless, which is what the server parses.
  static Map<String, String> get _identity =>
      kIsWeb ? const {} : const {'user-agent': 'Stockpile/1.0'};

  static void _identify(Map<String, String> headers) =>
      headers.addAll(_identity);

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> parsed;
    try {
      final decoded = response.body.isEmpty ? {} : jsonDecode(response.body);
      parsed = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      parsed = {};
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }

    final error = parsed['error'];
    if (error is Map) {
      throw AuthApiException(
        code: error['code'] as String? ?? 'unknown',
        message:
            error['message'] as String? ??
            'Something went wrong. Please try again.',
        details: [
          for (final detail in (error['details'] as List? ?? const []))
            if (detail is String) detail,
        ],
        statusCode: response.statusCode,
      );
    }

    // A response the API did not shape — a proxy error page, say. Never shown
    // verbatim, because it is not ours and may contain anything.
    throw AuthApiException(
      code: 'unknown',
      message: 'Something went wrong. Please try again.',
      statusCode: response.statusCode,
    );
  }

  Future<StoredTokens?> _refresh() {
    return _inFlightRefresh ??= _doRefresh().whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<StoredTokens?> _doRefresh() async {
    final current = _tokens;
    if (current == null || current.refreshExpired) {
      await forget();
      onSessionLost?.call();
      return null;
    }

    try {
      final response = await _client
          .post(
            endpointFor('/auth/refresh'),
            headers: {
              'content-type': 'application/json; charset=utf-8',
              ..._identity,
            },
            body: jsonEncode({'refreshToken': current.refreshToken}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        await forget();
        onSessionLost?.call();
        return null;
      }

      final tokens = _tokensFrom(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      // Rotation replaces both halves, so what is on disk must be replaced
      // too — keeping the old refresh token would trip the server's replay
      // detection on the next renewal.
      await _persist(tokens, remember: true);
      return tokens;
    } catch (_) {
      // A network failure is not a lost session: the tokens may still be
      // good, so they are kept and the caller sees the original error.
      return null;
    }
  }

  static StoredTokens _tokensFrom(Map<String, dynamic> body) {
    final session = body['session'] as Map<String, dynamic>;
    return StoredTokens(
      accessToken: session['accessToken'] as String,
      refreshToken: session['refreshToken'] as String,
      accessExpiresAt:
          DateTime.tryParse(
            session['accessExpiresAt'] as String? ?? '',
          )?.toLocal() ??
          DateTime.now().add(const Duration(minutes: 15)),
      refreshExpiresAt:
          DateTime.tryParse(
            session['refreshExpiresAt'] as String? ?? '',
          )?.toLocal() ??
          DateTime.now().add(const Duration(days: 30)),
    );
  }

  // -------------------------------------------------------------------
  // Authentication
  // -------------------------------------------------------------------

  Future<AuthUser> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    final body = await _send(
      'POST',
      '/auth/login',
      body: {'email': email, 'password': password},
      authenticated: false,
    );
    await _persist(_tokensFrom(body), remember: rememberMe);
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<AuthUser> me() async {
    final body = await _send('GET', '/auth/session/me');
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _send('POST', '/auth/session/logout');
    } on AuthApiException {
      // The local session is cleared regardless: a user who pressed "sign
      // out" must end up signed out even if the server is unreachable.
    } finally {
      await forget();
    }
  }

  Future<int> logoutEverywhere({bool keepCurrent = true}) async {
    final body = await _send(
      'POST',
      '/auth/session/logout-all',
      body: {'keepCurrent': keepCurrent},
    );
    if (!keepCurrent) await forget();
    return body['revoked'] as int? ?? 0;
  }

  Future<void> forgotPassword(String email) => _send(
    'POST',
    '/auth/forgot-password',
    body: {'email': email},
    authenticated: false,
  );

  Future<void> resetPassword({
    required String token,
    required String password,
  }) => _send(
    'POST',
    '/auth/reset-password',
    body: {'token': token, 'password': password},
    authenticated: false,
  );

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final body = await _send(
      'POST',
      '/auth/session/change-password',
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    );
    // The change invalidated every session including this one; the response
    // carries a replacement so the user is not thrown out for doing the right
    // thing.
    if (body['session'] != null) {
      await _persist(_tokensFrom(body), remember: true);
    }
  }

  Future<({String email, String name})> inspectInvitation(String token) async {
    final body = await _send(
      'GET',
      '/auth/invitation?token=${Uri.encodeQueryComponent(token)}',
      authenticated: false,
    );
    return (
      email: body['email'] as String? ?? '',
      name: body['name'] as String? ?? '',
    );
  }

  Future<void> acceptInvitation({
    required String token,
    required String password,
    String? name,
  }) => _send(
    'POST',
    '/auth/accept-invitation',
    body: {
      'token': token,
      'password': password,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    },
    authenticated: false,
  );

  Future<void> verifyEmail(String token) => _send(
    'POST',
    '/auth/verify-email',
    body: {'token': token},
    authenticated: false,
  );

  Future<void> resendVerification(String email) => _send(
    'POST',
    '/auth/resend-verification',
    body: {'email': email},
    authenticated: false,
  );

  // -------------------------------------------------------------------
  // Account (§16, §17, §18, §14)
  // -------------------------------------------------------------------

  Future<AuthUser> updateProfile({String? name, String? phone}) async {
    final body = await _send(
      'PATCH',
      '/account/profile',
      body: {'name': ?name, 'phone': ?phone},
    );
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<void> requestEmailChange({
    required String newEmail,
    required String currentPassword,
  }) => _send(
    'POST',
    '/account/email',
    body: {'email': newEmail, 'currentPassword': currentPassword},
  );

  Future<void> confirmEmailChange(String token) => _send(
    'POST',
    '/account/public/verify-email-change',
    body: {'token': token},
    authenticated: false,
  );

  Future<List<AuthSession>> sessions() async {
    final body = await _send('GET', '/account/sessions');
    return [
      for (final session in (body['sessions'] as List? ?? const []))
        AuthSession.fromJson(session as Map<String, dynamic>),
    ];
  }

  Future<void> revokeSession(String id) =>
      _send('DELETE', '/account/sessions/$id');

  Future<List<LoginActivity>> recentActivity() async {
    final body = await _send('GET', '/account/activity');
    return [
      for (final entry in (body['activity'] as List? ?? const []))
        LoginActivity.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<({List<NotificationChannel> channels, Map<String, bool> preferences})>
  notificationSettings() async {
    final body = await _send('GET', '/account/notifications');
    return (
      channels: [
        for (final channel in (body['channels'] as List? ?? const []))
          NotificationChannel.fromJson(channel as Map<String, dynamic>),
      ],
      preferences: _boolMap(body['preferences']),
    );
  }

  Future<Map<String, bool>> setNotificationPreferences(
    Map<String, bool> preferences,
  ) async {
    final body = await _send(
      'PATCH',
      '/account/notifications',
      body: preferences,
    );
    return _boolMap(body['preferences']);
  }

  // -------------------------------------------------------------------
  // Administration (§8, §9)
  // -------------------------------------------------------------------

  Future<({List<ManagedUser> users, int total})> listUsers({
    String? search,
    String? status,
    String? role,
    int limit = 25,
    int offset = 0,
  }) async {
    final query = <String, String>{
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      'status': ?status,
      'role': ?role,
      'limit': '$limit',
      'offset': '$offset',
    };
    final body = await _send(
      'GET',
      '/users?${Uri(queryParameters: query).query}',
    );
    return (
      users: [
        for (final user in (body['users'] as List? ?? const []))
          ManagedUser.fromJson(user as Map<String, dynamic>),
      ],
      total: body['total'] as int? ?? 0,
    );
  }

  Future<
    ({
      ManagedUser user,
      Map<String, bool> overrides,
      List<AuthSession> sessions,
    })
  >
  userDetail(String id) async {
    final body = await _send('GET', '/users/$id');
    return (
      user: ManagedUser.fromJson(body['user'] as Map<String, dynamic>),
      overrides: _boolMap(body['overrides']),
      sessions: [
        for (final session in (body['sessions'] as List? ?? const []))
          AuthSession.fromJson(session as Map<String, dynamic>),
      ],
    );
  }

  Future<List<AuthRole>> roles() async {
    final body = await _send('GET', '/users/roles');
    return [
      for (final role in (body['roles'] as List? ?? const []))
        AuthRole.fromJson(role as Map<String, dynamic>),
    ];
  }

  Future<List<AuthPermission>> permissions() async {
    final body = await _send('GET', '/users/permissions');
    return [
      for (final permission in (body['permissions'] as List? ?? const []))
        AuthPermission.fromJson(permission as Map<String, dynamic>),
    ];
  }

  /// Returns the invitation link only when the server has no SMTP configured,
  /// which is how a development setup completes the flow.
  Future<({ManagedUser user, String? invitationUrl})> inviteUser({
    required String email,
    required String name,
    required List<String> roles,
    String? phone,
    Map<String, bool> permissions = const {},
  }) async {
    final body = await _send(
      'POST',
      '/users',
      body: {
        'email': email,
        'name': name,
        'roles': roles,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (permissions.isNotEmpty) 'permissions': permissions,
      },
    );
    return (
      user: ManagedUser.fromJson(body['user'] as Map<String, dynamic>),
      invitationUrl: body['invitationUrl'] as String?,
    );
  }

  Future<ManagedUser> updateUser(
    String id, {
    String? name,
    String? phone,
  }) async {
    final body = await _send(
      'PATCH',
      '/users/$id',
      body: {'name': ?name, 'phone': ?phone},
    );
    return ManagedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<ManagedUser> setUserEnabled(String id, bool enabled) async {
    final body = await _send(
      'PATCH',
      '/users/$id/status',
      body: {'enabled': enabled},
    );
    return ManagedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<ManagedUser> setUserRoles(String id, List<String> roles) async {
    final body = await _send(
      'PATCH',
      '/users/$id/roles',
      body: {'roles': roles},
    );
    return ManagedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<Map<String, bool>> setUserPermissions(
    String id,
    Map<String, bool> overrides,
  ) async {
    final body = await _send(
      'PATCH',
      '/users/$id/permissions',
      body: {'permissions': overrides},
    );
    return _boolMap(body['overrides']);
  }

  Future<void> sendUserPasswordReset(String id) =>
      _send('POST', '/users/$id/reset-password');

  Future<ManagedUser> unlockUser(String id) async {
    final body = await _send('POST', '/users/$id/unlock');
    return ManagedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<void> resendInvitation(String id) =>
      _send('POST', '/users/$id/resend-invitation');

  Future<void> revokeInvitation(String id) =>
      _send('DELETE', '/users/$id/invitation');

  Future<void> deactivateUser(String id) => _send('DELETE', '/users/$id');

  Future<void> revokeUserSession(String userId, String sessionId) =>
      _send('DELETE', '/users/$userId/sessions/$sessionId');

  // -------------------------------------------------------------------
  // Audit (§20)
  // -------------------------------------------------------------------

  Future<({List<AuditEntry> entries, int total})> auditLogs({
    String? action,
    String? actorId,
    String? search,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    int offset = 0,
  }) async {
    String day(DateTime value) =>
        value.toUtc().toIso8601String().substring(0, 10);

    final query = <String, String>{
      'action': ?action,
      'actor': ?actorId,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      if (from != null) 'from': day(from),
      if (to != null) 'to': day(to),
      'limit': '$limit',
      'offset': '$offset',
    };
    final body = await _send(
      'GET',
      '/audit-logs?${Uri(queryParameters: query).query}',
    );
    return (
      entries: [
        for (final entry in (body['entries'] as List? ?? const []))
          AuditEntry.fromJson(entry as Map<String, dynamic>),
      ],
      total: body['total'] as int? ?? 0,
    );
  }

  Future<List<String>> auditActions() async {
    final body = await _send('GET', '/audit-logs/actions');
    return [
      for (final action in (body['actions'] as List? ?? const []))
        if (action is String) action,
    ];
  }

  void dispose() => _client.close();

  static Map<String, bool> _boolMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is bool)
          entry.key as String: entry.value as bool,
    };
  }
}

/// A switchable application-notification channel (§14).
class NotificationChannel {
  const NotificationChannel({
    required this.key,
    required this.name,
    required this.description,
  });

  final String key;
  final String name;
  final String description;

  static NotificationChannel fromJson(Map<String, dynamic> json) =>
      NotificationChannel(
        key: json['key'] as String,
        name: json['name'] as String? ?? json['key'] as String,
        description: json['description'] as String? ?? '',
      );
}
