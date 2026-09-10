import 'package:drift/drift.dart';

import '../db/database.dart';
import 'permissions.dart';

/// Resolves what a user may do.
///
/// Effective permissions are the union of every role's grants, with per-user
/// overrides applied last: an explicit grant adds one, and an explicit denial
/// removes one even if a role would have supplied it. Denial wins, so
/// withholding a capability from one person never requires cloning a role.
class AccessService {
  AccessService(this._db);

  final AuthDatabase _db;

  Future<Set<String>> roleKeysFor(String userId) async {
    final query = _db.select(_db.userRoles).join([
      innerJoin(_db.roles, _db.roles.id.equalsExp(_db.userRoles.roleId)),
    ])..where(_db.userRoles.userId.equals(userId));
    final rows = await query.get();
    return rows.map((r) => r.readTable(_db.roles).key).toSet();
  }

  /// The full permission set for [userId].
  Future<Set<String>> permissionsFor(String userId) async {
    final granted = <String>{};

    final fromRoles = await (_db.select(_db.rolePermissions).join([
      innerJoin(
        _db.userRoles,
        _db.userRoles.roleId.equalsExp(_db.rolePermissions.roleId),
      ),
    ])..where(_db.userRoles.userId.equals(userId))).get();
    for (final row in fromRoles) {
      granted.add(row.readTable(_db.rolePermissions).permissionKey);
    }

    final overrides = await (_db.select(
      _db.userPermissions,
    )..where((t) => t.userId.equals(userId))).get();
    for (final override in overrides) {
      if (override.granted) {
        granted.add(override.permissionKey);
      } else {
        granted.remove(override.permissionKey);
      }
    }

    // A permission retired from the catalogue but still sitting in an old
    // grant row must not keep working.
    granted.removeWhere((key) => !permissionsByKey.containsKey(key));
    return granted;
  }

  /// Roles and permissions in one pass, for the login and `/auth/me` paths
  /// where both are always needed.
  Future<({Set<String> roles, Set<String> permissions})> resolve(
    String userId,
  ) async {
    final roles = await roleKeysFor(userId);
    final permissions = await permissionsFor(userId);
    return (roles: roles, permissions: permissions);
  }

  /// True when [userId] is the last account that can still administer the
  /// system.
  ///
  /// Guards the two operations that could otherwise lock everyone out — the
  /// admin disabling or demoting themselves — which is a far more common
  /// accident than it sounds.
  Future<bool> isLastActiveAdministrator(String userId) async {
    final administrators =
        await (_db.select(_db.userRoles).join([
                innerJoin(
                  _db.roles,
                  _db.roles.id.equalsExp(_db.userRoles.roleId),
                ),
                innerJoin(
                  _db.users,
                  _db.users.id.equalsExp(_db.userRoles.userId),
                ),
              ])
              ..where(_db.roles.key.equals(administratorRoleKey))
              ..where(_db.users.deletedAt.isNull())
              ..where(_db.users.status.equals('active')))
            .get();

    final ids = administrators.map((r) => r.readTable(_db.users).id).toSet();
    return ids.length <= 1 && ids.contains(userId);
  }
}
