import '../db/database.dart';
import '../email/notification_service.dart';
import '../rbac/permissions.dart';
import '../rbac/principal.dart';
import '../users/user_service.dart';

/// Model-to-JSON conversion.
///
/// Every function here builds its map field by field rather than dumping a
/// row, which is what guarantees `password_hash`, `access_token_hash`,
/// `refresh_token_hash` and `token_hash` can never leave the server (§11).
/// Adding a sensitive column to a table does not silently start exposing it.

Map<String, Object?> userJson(User user) => {
  'id': user.id,
  'email': user.email,
  'name': user.name,
  'phone': user.phone,
  'status': user.status,
  'emailVerified': user.emailVerified,
  'emailVerifiedAt': user.emailVerifiedAt?.toIso8601String(),
  'lastLoginAt': user.lastLoginAt?.toIso8601String(),
  'lockedUntil': user.lockedUntil?.toIso8601String(),
  'createdAt': user.createdAt.toIso8601String(),
  'updatedAt': user.updatedAt.toIso8601String(),
};

Map<String, Object?> userSummaryJson(UserSummary summary) => {
  ...userJson(summary.user),
  'roles': summary.roleKeys,
  'roleNames': summary.roleNames,
  'activeSessions': summary.activeSessions,
  // A convenience for the admin list, so the client does not reimplement the
  // "is this lock still in force?" comparison and get it subtly wrong.
  'isLocked':
      summary.user.lockedUntil?.isAfter(DateTime.now().toUtc()) ?? false,
};

/// The signed-in user's own view of themselves, including what they may do.
Map<String, Object?> principalJson(Principal principal) => {
  ...userJson(principal.user),
  'roles': principal.roleKeys.toList()..sort(),
  'permissions': principal.permissions.toList()..sort(),
  'sessionId': principal.sessionId,
};

Map<String, Object?> sessionJson(Session session, {required bool isCurrent}) =>
    {
      'id': session.id,
      'device': session.deviceLabel,
      'ipAddress': session.ipAddress,
      'createdAt': session.createdAt.toIso8601String(),
      'lastUsedAt': session.lastUsedAt.toIso8601String(),
      'expiresAt': session.refreshExpiresAt.toIso8601String(),
      'isCurrent': isCurrent,
    };

Map<String, Object?> loginAttemptJson(LoginAttempt attempt) => {
  'id': attempt.id,
  'succeeded': attempt.succeeded,
  'reason': attempt.failureReason,
  'ipAddress': attempt.ipAddress,
  'device': attempt.deviceLabel,
  'at': attempt.attemptedAt.toIso8601String(),
};

Map<String, Object?> auditLogJson(AuditLog entry) => {
  'id': entry.id,
  'actorId': entry.actorId,
  'actorEmail': entry.actorEmail,
  'action': entry.action,
  'targetType': entry.targetType,
  'targetId': entry.targetId,
  'targetLabel': entry.targetLabel,
  'result': entry.result,
  'metadata': entry.metadata,
  'ipAddress': entry.ipAddress,
  'at': entry.createdAt.toIso8601String(),
};

Map<String, Object?> roleJson(Role role) => {
  'id': role.id,
  'key': role.key,
  'name': role.name,
  'description': role.description,
  'isSystem': role.isSystem,
};

Map<String, Object?> permissionJson(PermissionDef permission) => {
  'key': permission.key,
  'category': permission.category,
  'description': permission.description,
};

Map<String, Object?> notificationChannelJson(AppNotificationChannel channel) =>
    {
      'key': channel.key,
      'name': channel.name,
      'description': channel.description,
    };

/// The token pair, in the shape the client stores it.
Map<String, Object?> sessionTokensJson({
  required String accessToken,
  required String refreshToken,
  required DateTime accessExpiresAt,
  required DateTime refreshExpiresAt,
}) => {
  'accessToken': accessToken,
  'refreshToken': refreshToken,
  'accessExpiresAt': accessExpiresAt.toIso8601String(),
  'refreshExpiresAt': refreshExpiresAt.toIso8601String(),
};
