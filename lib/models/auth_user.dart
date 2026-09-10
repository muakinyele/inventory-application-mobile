/// The signed-in user, as the API describes them.
///
/// Permissions are carried as a resolved set rather than as roles, so a widget
/// asks "may I?" and never has to know which role supplied the answer — the
/// same shape the server uses, for the same reason.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.name,
    required this.status,
    required this.emailVerified,
    required this.roles,
    required this.permissions,
    required this.sessionId,
    this.phone,
    this.lastLoginAt,
    this.emailVerifiedAt,
    this.createdAt,
  });

  final String id;
  final String email;
  final String name;
  final String? phone;

  /// `active` | `pending` | `disabled`.
  final String status;

  final bool emailVerified;
  final Set<String> roles;
  final Set<String> permissions;

  /// Which device this is, so the security screen can mark "this session".
  final String sessionId;

  final DateTime? lastLoginAt;
  final DateTime? emailVerifiedAt;
  final DateTime? createdAt;

  bool can(String permission) => permissions.contains(permission);

  bool canAny(Iterable<String> required) => required.any(can);

  bool hasRole(String role) => roles.contains(role);

  /// Initials for the avatar, from the name if it has one and the address
  /// otherwise — an invited user may not have set a name yet.
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((part) => part.isEmpty);
    if (parts.isEmpty) return email.isEmpty ? '?' : email[0].toUpperCase();
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  static AuthUser fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String,
      name: json['name'] as String? ?? '',
      phone: json['phone'] as String?,
      status: json['status'] as String? ?? 'active',
      emailVerified: json['emailVerified'] as bool? ?? false,
      roles: _stringSet(json['roles']),
      permissions: _stringSet(json['permissions']),
      sessionId: json['sessionId'] as String? ?? '',
      lastLoginAt: _date(json['lastLoginAt']),
      emailVerifiedAt: _date(json['emailVerifiedAt']),
      createdAt: _date(json['createdAt']),
    );
  }

  AuthUser copyWith({
    String? name,
    String? phone,
    String? email,
    bool? emailVerified,
  }) {
    return AuthUser(
      id: id,
      email: email ?? this.email,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      status: status,
      emailVerified: emailVerified ?? this.emailVerified,
      roles: roles,
      permissions: permissions,
      sessionId: sessionId,
      lastLoginAt: lastLoginAt,
      emailVerifiedAt: emailVerifiedAt,
      createdAt: createdAt,
    );
  }

  static Set<String> _stringSet(Object? value) {
    if (value is! List) return const {};
    return {
      for (final entry in value)
        if (entry is String) entry,
    };
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

/// One signed-in device, for the security screen (§18).
class AuthSession {
  const AuthSession({
    required this.id,
    required this.device,
    required this.isCurrent,
    required this.lastUsedAt,
    required this.createdAt,
    this.ipAddress,
  });

  final String id;
  final String device;
  final bool isCurrent;
  final DateTime lastUsedAt;
  final DateTime createdAt;
  final String? ipAddress;

  static AuthSession fromJson(Map<String, dynamic> json) => AuthSession(
    id: json['id'] as String,
    device: json['device'] as String? ?? 'Unknown device',
    isCurrent: json['isCurrent'] as bool? ?? false,
    lastUsedAt:
        DateTime.tryParse(json['lastUsedAt'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    ipAddress: json['ipAddress'] as String?,
  );
}

/// A sign-in attempt, for "recent activity" (§17).
class LoginActivity {
  const LoginActivity({
    required this.id,
    required this.succeeded,
    required this.at,
    this.reason,
    this.device,
    this.ipAddress,
  });

  final String id;
  final bool succeeded;
  final DateTime at;
  final String? reason;
  final String? device;
  final String? ipAddress;

  /// The failure reasons the API emits, in words.
  String get description {
    if (succeeded) return 'Signed in';
    return switch (reason) {
      'bad_password' => 'Wrong password',
      'no_account' => 'No such account',
      'locked' => 'Blocked — account locked',
      'disabled' => 'Blocked — account disabled',
      'unverified' => 'Blocked — email not confirmed',
      'pending' => 'Blocked — invitation not accepted',
      'throttled' => 'Blocked — too many attempts',
      _ => 'Sign-in failed',
    };
  }

  static LoginActivity fromJson(Map<String, dynamic> json) => LoginActivity(
    id: json['id'] as String,
    succeeded: json['succeeded'] as bool? ?? false,
    at:
        DateTime.tryParse(json['at'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    reason: json['reason'] as String?,
    device: json['device'] as String?,
    ipAddress: json['ipAddress'] as String?,
  );
}

/// A managed user in the admin list (§8).
class ManagedUser {
  const ManagedUser({
    required this.id,
    required this.email,
    required this.name,
    required this.status,
    required this.emailVerified,
    required this.roles,
    required this.roleNames,
    required this.isLocked,
    required this.activeSessions,
    this.phone,
    this.lastLoginAt,
    this.createdAt,
  });

  final String id;
  final String email;
  final String name;
  final String? phone;
  final String status;
  final bool emailVerified;
  final List<String> roles;
  final List<String> roleNames;
  final bool isLocked;
  final int activeSessions;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;

  /// What the status chip shows. Locked outranks the stored status, because
  /// it is the thing stopping them signing in right now.
  String get statusLabel {
    if (isLocked) return 'Locked';
    return switch (status) {
      'active' => 'Active',
      'pending' => 'Pending',
      'disabled' => 'Disabled',
      _ => status,
    };
  }

  static ManagedUser fromJson(Map<String, dynamic> json) => ManagedUser(
    id: json['id'] as String,
    email: json['email'] as String,
    name: json['name'] as String? ?? '',
    phone: json['phone'] as String?,
    status: json['status'] as String? ?? 'active',
    emailVerified: json['emailVerified'] as bool? ?? false,
    roles: [
      for (final role in (json['roles'] as List? ?? const []))
        if (role is String) role,
    ],
    roleNames: [
      for (final role in (json['roleNames'] as List? ?? const []))
        if (role is String) role,
    ],
    isLocked: json['isLocked'] as bool? ?? false,
    activeSessions: json['activeSessions'] as int? ?? 0,
    lastLoginAt: AuthUser._date(json['lastLoginAt']),
    createdAt: AuthUser._date(json['createdAt']),
  );
}

/// A role, for the pickers.
class AuthRole {
  const AuthRole({
    required this.key,
    required this.name,
    required this.description,
  });

  final String key;
  final String name;
  final String description;

  static AuthRole fromJson(Map<String, dynamic> json) => AuthRole(
    key: json['key'] as String,
    name: json['name'] as String? ?? json['key'] as String,
    description: json['description'] as String? ?? '',
  );
}

/// One permission in the catalogue, for the granular picker (§7).
class AuthPermission {
  const AuthPermission({
    required this.key,
    required this.category,
    required this.description,
  });

  final String key;
  final String category;
  final String description;

  static AuthPermission fromJson(Map<String, dynamic> json) => AuthPermission(
    key: json['key'] as String,
    category: json['category'] as String? ?? 'Other',
    description: json['description'] as String? ?? '',
  );
}

/// An audit record (§20).
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.result,
    required this.at,
    this.actorEmail,
    this.targetLabel,
    this.targetType,
    this.ipAddress,
    this.metadata,
  });

  final String id;
  final String action;
  final String result;
  final DateTime at;
  final String? actorEmail;
  final String? targetLabel;
  final String? targetType;
  final String? ipAddress;
  final String? metadata;

  bool get failed => result == 'failure';

  /// `auth.login_failed` reads as "Sign-in failed". Falls back to a
  /// de-slugged version of the key, so a new server-side action still renders
  /// legibly without a client release.
  String get label => _actionLabels[action] ?? _humanise(action);

  static String _humanise(String action) {
    final tail = action.contains('.') ? action.split('.').last : action;
    final words = tail.replaceAll('_', ' ');
    return words.isEmpty
        ? action
        : '${words[0].toUpperCase()}${words.substring(1)}';
  }

  static const Map<String, String> _actionLabels = {
    'auth.login': 'Signed in',
    'auth.login_failed': 'Sign-in failed',
    'auth.logout': 'Signed out',
    'auth.logout_all': 'Signed out everywhere',
    'auth.token_refreshed': 'Session renewed',
    'auth.refresh_replayed': 'Reused session token',
    'auth.account_locked': 'Account locked',
    'password.changed': 'Password changed',
    'password.reset_requested': 'Password reset requested',
    'password.reset_completed': 'Password reset completed',
    'password.reset_by_admin': 'Password reset by administrator',
    'email.verification_sent': 'Verification email sent',
    'email.verified': 'Email confirmed',
    'email.change_requested': 'Email change requested',
    'email.changed': 'Email changed',
    'user.invited': 'User invited',
    'user.invitation_accepted': 'Invitation accepted',
    'user.invitation_revoked': 'Invitation cancelled',
    'user.created': 'User created',
    'user.updated': 'User updated',
    'user.enabled': 'User enabled',
    'user.disabled': 'User disabled',
    'user.deleted': 'User deactivated',
    'user.unlocked': 'Account unlocked',
    'user.profile_updated': 'Profile updated',
    'rbac.roles_changed': 'Roles changed',
    'rbac.permissions_changed': 'Permissions changed',
    'session.revoked': 'Device signed out',
    'notifications.changed': 'Notification settings changed',
  };

  static AuditEntry fromJson(Map<String, dynamic> json) => AuditEntry(
    id: json['id'] as String,
    action: json['action'] as String,
    result: json['result'] as String? ?? 'success',
    at:
        DateTime.tryParse(json['at'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    actorEmail: json['actorEmail'] as String?,
    targetLabel: json['targetLabel'] as String?,
    targetType: json['targetType'] as String?,
    ipAddress: json['ipAddress'] as String?,
    metadata: json['metadata'] as String?,
  );
}
