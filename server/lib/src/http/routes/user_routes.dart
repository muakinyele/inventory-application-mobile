import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../rbac/permissions.dart';
import '../../users/user_service.dart';
import '../api_error.dart';
import '../middleware.dart';
import '../request_context.dart';
import '../serializers.dart';

/// Administration of other people's accounts (§8, §9, §22).
///
/// Each handler opens with its own `request.require(...)`, rather than the
/// whole router sitting behind one blanket "is an admin" check. That is what
/// makes the permission system real: a role that can view users but not
/// disable them is expressible without restructuring this file.
Router userRoutes({required UserService users}) {
  final router = Router();

  // ------------------------------------------------------------------
  // GET /users — searched, filtered, paged (§8)
  // ------------------------------------------------------------------
  router.get('/', (Request request) async {
    request.require('users.view');

    final query = request.url.queryParameters;
    final page = await users.list(
      search: query['search'],
      status: query['status'],
      roleKey: query['role'],
      limit: _boundedInt(query['limit'], fallback: 25, min: 1, max: 100),
      offset: _boundedInt(query['offset'], fallback: 0, min: 0, max: 1 << 30),
    );
    return jsonResponse({
      'users': [for (final user in page.users) userSummaryJson(user)],
      'total': page.total,
    });
  });

  // ------------------------------------------------------------------
  // The pickers behind the invite and edit forms
  // ------------------------------------------------------------------
  router.get('/roles', (Request request) async {
    request.require('users.view');
    return jsonResponse({
      'roles': [for (final role in await users.allRoles()) roleJson(role)],
    });
  });

  router.get('/permissions', (Request request) async {
    request.require('users.view');
    return jsonResponse({
      'permissions': [
        for (final permission in allPermissions) permissionJson(permission),
      ],
    });
  });

  // ------------------------------------------------------------------
  // POST /users — invite (§9)
  // ------------------------------------------------------------------
  router.post('/', (Request request) async {
    final actor = request.require('users.create');

    final body = await readJsonBody(request);
    final email = body['email'];
    final name = body['name'];
    if (email is! String || email.trim().isEmpty) {
      throw ApiError.badRequest('"email" is required.');
    }
    if (name is! String || name.trim().isEmpty) {
      throw ApiError.badRequest('"name" is required.');
    }

    final outcome = await users.invite(
      actor: actor,
      email: email,
      name: name,
      phone: body['phone'] as String?,
      roleKeys: _stringList(body['roles']),
      permissionOverrides: _boolMap(body['permissions']),
      ipAddress: request.clientIp,
    );
    if (!outcome.result.isSuccess) throw _mutationError(outcome.result.error!);

    final created = await users.byId(outcome.result.user!.id);
    return jsonResponse({
      'user': userSummaryJson(created!),
      // Returned only when mail is not configured, so a development setup can
      // complete the flow. In production the link goes to the mailbox and
      // nowhere else.
      if (!users.env.emailEnabled)
        'invitationUrl':
            '${users.env.appUrl}/#/accept-invitation?token=${outcome.token}',
    }, statusCode: 201);
  });

  // ------------------------------------------------------------------
  // GET /users/<id>
  // ------------------------------------------------------------------
  router.get('/<id>', (Request request, String id) async {
    request.require('users.view');

    final user = await users.byId(id);
    if (user == null) throw ApiError.notFound;
    return jsonResponse({
      'user': userSummaryJson(user),
      'overrides': await users.overridesFor(id),
      'sessions': [
        for (final session in await users.sessionsOf(id))
          sessionJson(session, isCurrent: false),
      ],
    });
  });

  // ------------------------------------------------------------------
  // PATCH /users/<id>
  // ------------------------------------------------------------------
  router.patch('/<id>', (Request request, String id) async {
    final actor = request.require('users.update');

    final body = await readJsonBody(request);
    final result = await users.updateDetails(
      actor: actor,
      userId: id,
      name: body['name'] as String?,
      phone: body['phone'] as String?,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'user': userSummaryJson((await users.byId(id))!)});
  });

  // ------------------------------------------------------------------
  // PATCH /users/<id>/status — enable / disable (§8)
  // ------------------------------------------------------------------
  router.patch('/<id>/status', (Request request, String id) async {
    final actor = request.require('users.disable');

    final body = await readJsonBody(request);
    final enabled = body['enabled'];
    if (enabled is! bool) {
      throw ApiError.badRequest('"enabled" must be true or false.');
    }

    final result = await users.setEnabled(
      actor: actor,
      userId: id,
      enabled: enabled,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'user': userSummaryJson((await users.byId(id))!)});
  });

  // ------------------------------------------------------------------
  // Roles and per-user permissions (§6, §7)
  // ------------------------------------------------------------------
  router.patch('/<id>/roles', (Request request, String id) async {
    final actor = request.require('roles.manage');

    final body = await readJsonBody(request);
    final result = await users.setRoles(
      actor: actor,
      userId: id,
      roleKeys: _stringList(body['roles']),
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'user': userSummaryJson((await users.byId(id))!)});
  });

  router.patch('/<id>/permissions', (Request request, String id) async {
    final actor = request.require('roles.manage');

    final body = await readJsonBody(request);
    final result = await users.setPermissionOverrides(
      actor: actor,
      userId: id,
      overrides: _boolMap(body['permissions']),
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'overrides': await users.overridesFor(id)});
  });

  // ------------------------------------------------------------------
  // Password reset and unlock (§8, §19)
  // ------------------------------------------------------------------
  router.post('/<id>/reset-password', (Request request, String id) async {
    final actor = request.require('users.reset_password');

    final result = await users.sendPasswordReset(
      actor: actor,
      userId: id,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({
      'message':
          'A password reset link has been sent, and their devices have been '
          'signed out.',
    });
  });

  router.post('/<id>/unlock', (Request request, String id) async {
    final actor = request.require('users.update');

    final result = await users.unlock(
      actor: actor,
      userId: id,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'user': userSummaryJson((await users.byId(id))!)});
  });

  // ------------------------------------------------------------------
  // Invitations (§9)
  // ------------------------------------------------------------------
  router.post('/<id>/resend-invitation', (Request request, String id) async {
    final actor = request.require('users.create');

    final result = await users.resendInvitation(
      actor: actor,
      userId: id,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'message': 'The invitation has been sent again.'});
  });

  router.delete('/<id>/invitation', (Request request, String id) async {
    final actor = request.require('users.delete');

    final result = await users.revokeInvitation(
      actor: actor,
      userId: id,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'message': 'The invitation has been cancelled.'});
  });

  // ------------------------------------------------------------------
  // Revoking someone else's device (§18)
  //
  // Declared before `DELETE /<id>` so the more specific path wins the match.
  // ------------------------------------------------------------------
  router.delete('/<id>/sessions/<sessionId>', (
    Request request,
    String id,
    String sessionId,
  ) async {
    final actor = request.require('sessions.revoke');

    final revoked = await users.revokeSession(
      actor: actor,
      sessionId: sessionId,
      ipAddress: request.clientIp,
    );
    if (!revoked) throw ApiError.notFound;
    return jsonResponse({'message': 'That device has been signed out.'});
  });

  // ------------------------------------------------------------------
  // DELETE /users/<id> — soft delete (§8)
  // ------------------------------------------------------------------
  router.delete('/<id>', (Request request, String id) async {
    final actor = request.require('users.delete');

    final result = await users.deactivate(
      actor: actor,
      userId: id,
      ipAddress: request.clientIp,
    );
    if (!result.isSuccess) throw _mutationError(result.error!);
    return jsonResponse({'message': 'That account has been deactivated.'});
  });

  return router;
}

ApiError _mutationError(UserMutationError error) => switch (error) {
  UserMutationError.notFound => ApiError.notFound,
  UserMutationError.emailInUse => ApiError.emailInUse,
  UserMutationError.invalidEmail => ApiError.invalidEmail,
  UserMutationError.invalidRole => ApiError.badRequest(
    'That role does not exist.',
  ),
  UserMutationError.invalidPermission => ApiError.badRequest(
    'That permission does not exist.',
  ),
  UserMutationError.lastAdministrator => ApiError.lastAdministrator,
  UserMutationError.cannotTargetSelf => ApiError.cannotTargetSelf,
};

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}

Map<String, bool> _boolMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is bool)
        entry.key as String: entry.value as bool,
  };
}

/// Query-string integers are attacker-controlled, so they are clamped rather
/// than trusted — an unbounded `limit` is a cheap way to make the server read
/// the whole table.
int _boundedInt(
  String? raw, {
  required int fallback,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}
