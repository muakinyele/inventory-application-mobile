import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../email/notification_service.dart';
import '../../users/account_service.dart';
import '../api_error.dart';
import '../middleware.dart';
import '../request_context.dart';
import '../serializers.dart';

/// A signed-in user managing their own account (§16, §17, §18, §14).
///
/// Every handler acts on `request.principal` and never on an id from the
/// request, which is what makes it impossible to reach someone else's profile
/// or sessions through these routes however the URL is crafted.
Router accountRoutes({required AccountService account}) {
  final router = Router();

  // ------------------------------------------------------------------
  // Profile (§16)
  // ------------------------------------------------------------------
  router.patch('/profile', (Request request) async {
    final body = await readJsonBody(request);
    final user = await account.updateProfile(
      principal: request.principal,
      name: body['name'] as String?,
      phone: body['phone'] as String?,
      ipAddress: request.clientIp,
    );
    if (user == null) throw ApiError.notFound;
    return jsonResponse({'user': userJson(user)});
  });

  /// Changing the address is a two-step flow, so this only starts it. The
  /// account keeps its current address until the new one is confirmed.
  router.post('/email', (Request request) async {
    final body = await readJsonBody(request);
    final newEmail = body['email'];
    final password = body['currentPassword'];
    if (newEmail is! String || newEmail.trim().isEmpty) {
      throw ApiError.badRequest('"email" is required.');
    }
    if (password is! String || password.isEmpty) {
      throw ApiError.badRequest('"currentPassword" is required.');
    }

    final error = await account.requestEmailChange(
      principal: request.principal,
      newEmail: newEmail,
      currentPassword: password,
      ipAddress: request.clientIp,
    );
    if (error != null) throw _accountError(error);

    return jsonResponse({
      'message':
          'Check the new address for a confirmation link. Your current '
          'address stays in place until you confirm.',
    });
  });

  // ------------------------------------------------------------------
  // Sessions and devices (§18)
  // ------------------------------------------------------------------
  router.get('/sessions', (Request request) async {
    final sessions = await account.activeSessions(request.principal);
    return jsonResponse({
      'sessions': [
        for (final entry in sessions)
          sessionJson(entry.session, isCurrent: entry.isCurrent),
      ],
    });
  });

  router.delete('/sessions/<id>', (Request request, String id) async {
    final revoked = await account.revokeOwnSession(
      principal: request.principal,
      sessionId: id,
      ipAddress: request.clientIp,
    );
    // A session belonging to someone else is reported as absent rather than
    // forbidden, so the endpoint cannot be used to probe for valid ids.
    if (!revoked) throw ApiError.notFound;
    return jsonResponse({'message': 'That device has been signed out.'});
  });

  // ------------------------------------------------------------------
  // Security activity (§17)
  // ------------------------------------------------------------------
  router.get('/activity', (Request request) async {
    final attempts = await account.recentActivity(request.principal);
    return jsonResponse({
      'activity': [for (final attempt in attempts) loginAttemptJson(attempt)],
    });
  });

  // ------------------------------------------------------------------
  // Notification preferences (§14)
  // ------------------------------------------------------------------
  router.get('/notifications', (Request request) async {
    return jsonResponse({
      'channels': [
        for (final channel in appNotificationChannels)
          notificationChannelJson(channel),
      ],
      'preferences': await account.notificationPreferences(request.principal),
    });
  });

  router.patch('/notifications', (Request request) async {
    final body = await readJsonBody(request);
    final preferences = <String, bool>{};
    for (final entry in body.entries) {
      if (entry.value is bool) preferences[entry.key] = entry.value as bool;
    }

    // Unknown keys — including any attempt to name a security notification —
    // are dropped by the service rather than rejected, so a client sending a
    // stale channel name still gets its valid changes applied.
    final updated = await account.setNotificationPreferences(
      principal: request.principal,
      preferences: preferences,
      ipAddress: request.clientIp,
    );
    return jsonResponse({'preferences': updated});
  });

  return router;
}

/// Confirming an email change is reachable without a token: the link is
/// followed from a mailbox, which may not be the signed-in device.
Router publicAccountRoutes({required AccountService account}) {
  final router = Router();

  router.post('/verify-email-change', (Request request) async {
    final body = await readJsonBody(request);
    final token = body['token'];
    if (token is! String || token.isEmpty) throw ApiError.tokenInvalid;

    final error = await account.confirmEmailChange(
      token: token,
      ipAddress: request.clientIp,
    );
    if (error != null) throw _accountError(error);

    return jsonResponse({'message': 'Your email address has been updated.'});
  });

  return router;
}

ApiError _accountError(AccountError error) => switch (error) {
  AccountError.wrongPassword => ApiError.wrongCurrentPassword,
  AccountError.emailInUse => ApiError.emailInUse,
  AccountError.invalidEmail => ApiError.invalidEmail,
  AccountError.notFound => ApiError.notFound,
  AccountError.tokenBad => ApiError.tokenInvalid,
};
