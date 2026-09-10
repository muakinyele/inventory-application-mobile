import '../db/database.dart';

/// The authenticated caller, resolved once per request.
///
/// Carries the *effective* permission set rather than the roles it came from,
/// so a handler asks one question — "may you do this?" — and never has to know
/// how the answer was assembled.
class Principal {
  Principal({
    required this.user,
    required this.sessionId,
    required this.roleKeys,
    required this.permissions,
  });

  final User user;

  /// Which session made this request. Needed so the security screen can mark
  /// "this device" and so revoking it can be distinguished from revoking
  /// another.
  final String sessionId;

  final Set<String> roleKeys;

  /// The resolved union of role grants and per-user overrides.
  final Set<String> permissions;

  String get id => user.id;
  String get email => user.email;

  bool can(String permission) => permissions.contains(permission);

  bool canAll(Iterable<String> required) => required.every(can);

  bool canAny(Iterable<String> required) => required.any(can);

  bool hasRole(String roleKey) => roleKeys.contains(roleKey);
}
