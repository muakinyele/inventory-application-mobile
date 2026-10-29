import 'package:drift/drift.dart';

import 'auth/token_store.dart';
import 'auth/tokens.dart';
import 'db/database.dart';
import 'inventory/inventory_service.dart';
import 'rbac/permissions.dart';

/// Brings a database up to date with the permission catalogue and the roles
/// the system ships with.
///
/// Runs on every boot and is idempotent. Making it a startup step rather than
/// a migration means adding a permission to `permissions.dart` and deploying
/// is all it takes — there is no separate seed script to forget.
class Bootstrap {
  Bootstrap(this.db);

  final AuthDatabase db;

  Future<void> run() async {
    await _syncPermissions();
    await _syncSystemRoles();
    // Items restored with a total and no per-location stock: give the total a
    // location. No total changes. Safe on every boot; a no-op once aligned.
    await InventoryService(db).alignAllStockBins();
  }

  Future<void> _syncPermissions() async {
    await db.batch((batch) {
      batch.insertAllOnConflictUpdate(db.permissions, [
        for (final permission in allPermissions)
          PermissionsCompanion.insert(
            key: permission.key,
            description: Value(permission.description),
            category: permission.category,
          ),
      ]);
    });
    // A permission dropped from the catalogue is deliberately left in the
    // table. Deleting it would cascade grants away silently; leaving it means
    // `AccessService` ignores it while an administrator can still see what a
    // role used to hold.
  }

  Future<void> _syncSystemRoles() async {
    final now = DateTime.now().toUtc();

    for (final systemRole in systemRoles) {
      final existing = await (db.select(
        db.roles,
      )..where((t) => t.key.equals(systemRole.key))).getSingleOrNull();

      final roleId = existing?.id ?? newId();
      if (existing == null) {
        await db
            .into(db.roles)
            .insert(
              RolesCompanion.insert(
                id: roleId,
                key: systemRole.key,
                name: systemRole.name,
                description: Value(systemRole.description),
                isSystem: const Value(true),
                createdAt: now,
              ),
            );
      } else {
        await (db.update(db.roles)..where((t) => t.id.equals(roleId))).write(
          RolesCompanion(
            name: Value(systemRole.name),
            description: Value(systemRole.description),
            isSystem: const Value(true),
          ),
        );
      }

      // Grants are replaced rather than merged, so a permission removed from a
      // system role in code is genuinely removed on deploy. Custom roles an
      // administrator created are untouched by any of this.
      await db.transaction(() async {
        await (db.delete(
          db.rolePermissions,
        )..where((t) => t.roleId.equals(roleId))).go();
        await db.batch((batch) {
          batch.insertAll(db.rolePermissions, [
            for (final key in systemRole.permissions)
              if (permissionsByKey.containsKey(key))
                RolePermissionsCompanion.insert(
                  roleId: roleId,
                  permissionKey: key,
                ),
          ]);
        });
      });
    }
  }

  /// True when nobody can administer the system yet, which is what
  /// `bin/create_admin.dart` checks before offering to create the first one.
  Future<bool> needsFirstAdministrator() async {
    final rows =
        await (db.select(db.userRoles).join([
                innerJoin(db.roles, db.roles.id.equalsExp(db.userRoles.roleId)),
                innerJoin(db.users, db.users.id.equalsExp(db.userRoles.userId)),
              ])
              ..where(db.roles.key.equals(administratorRoleKey))
              ..where(db.users.deletedAt.isNull())
              ..limit(1))
            .get();
    return rows.isEmpty;
  }

  /// Creates the first administrator and returns the invitation token.
  ///
  /// The account is created *pending with no password* and claimed through the
  /// normal invitation link, so even the bootstrap path never puts a password
  /// on a command line or in a shell history file.
  Future<({String userId, String token})> createFirstAdministrator({
    required String email,
    required String name,
    required TokenStore tokenStore,
    required Duration validFor,
  }) async {
    final now = DateTime.now().toUtc();
    final id = newId();
    final role = await (db.select(
      db.roles,
    )..where((t) => t.key.equals(administratorRoleKey))).getSingle();

    await db.transaction(() async {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: id,
              email: email.trim().toLowerCase(),
              name: name.trim(),
              status: const Value('pending'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.userRoles)
          .insert(
            UserRolesCompanion.insert(
              userId: id,
              roleId: role.id,
              grantedAt: now,
            ),
          );
    });

    final token = await tokenStore.issue(
      userId: id,
      purpose: TokenPurpose.invitation,
      validFor: validFor,
    );
    return (userId: id, token: token);
  }
}
