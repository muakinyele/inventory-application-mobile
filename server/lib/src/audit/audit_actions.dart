/// The vocabulary of the audit trail.
///
/// Constants rather than free strings so the admin filter can offer a closed
/// list, and so a typo in a handler cannot silently create a new event type
/// that nobody ever filters for.
abstract final class AuditAction {
  static const login = 'auth.login';
  static const loginFailed = 'auth.login_failed';
  static const logout = 'auth.logout';
  static const logoutAll = 'auth.logout_all';
  static const tokenRefreshed = 'auth.token_refreshed';
  static const refreshReplayed = 'auth.refresh_replayed';
  static const accountLocked = 'auth.account_locked';

  static const passwordChanged = 'password.changed';
  static const passwordResetRequested = 'password.reset_requested';
  static const passwordResetCompleted = 'password.reset_completed';
  static const passwordResetByAdmin = 'password.reset_by_admin';

  static const emailVerificationSent = 'email.verification_sent';
  static const emailVerified = 'email.verified';
  static const emailChangeRequested = 'email.change_requested';
  static const emailChanged = 'email.changed';

  static const userInvited = 'user.invited';
  static const invitationAccepted = 'user.invitation_accepted';
  static const invitationRevoked = 'user.invitation_revoked';
  static const userCreated = 'user.created';
  static const userUpdated = 'user.updated';
  static const userEnabled = 'user.enabled';
  static const userDisabled = 'user.disabled';
  static const userDeleted = 'user.deleted';
  static const userUnlocked = 'user.unlocked';
  static const profileUpdated = 'user.profile_updated';

  static const rolesChanged = 'rbac.roles_changed';
  static const permissionsChanged = 'rbac.permissions_changed';

  static const sessionRevoked = 'session.revoked';

  static const notificationPreferencesChanged = 'notifications.changed';

  /// Everything above, for the filter dropdown.
  static const all = [
    login,
    loginFailed,
    logout,
    logoutAll,
    tokenRefreshed,
    refreshReplayed,
    accountLocked,
    passwordChanged,
    passwordResetRequested,
    passwordResetCompleted,
    passwordResetByAdmin,
    emailVerificationSent,
    emailVerified,
    emailChangeRequested,
    emailChanged,
    userInvited,
    invitationAccepted,
    invitationRevoked,
    userCreated,
    userUpdated,
    userEnabled,
    userDisabled,
    userDeleted,
    userUnlocked,
    profileUpdated,
    rolesChanged,
    permissionsChanged,
    sessionRevoked,
    notificationPreferencesChanged,
  ];
}
