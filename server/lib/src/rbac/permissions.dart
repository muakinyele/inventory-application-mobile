/// The permission catalogue (§7).
///
/// Permissions — not roles — are what the API checks. A role is only a named
/// bundle of these, which is what lets a new capability be added by appending
/// one row here and granting it, rather than by editing conditionals spread
/// across handlers.
///
/// Keys are `resource.action` and are stable: they are stored in
/// `role_permissions`, so renaming one is a migration, not an edit.
/// Named `PermissionDef` rather than `Permission` because drift generates a
/// `Permission` row class for the `permissions` table, and a catalogue entry
/// and a database row are different things worth telling apart.
class PermissionDef {
  const PermissionDef(this.key, this.category, this.description);

  final String key;

  /// Groups the permission in the admin picker.
  final String category;

  final String description;
}

/// Every permission the system knows about.
///
/// Seeded into the `permissions` table at boot. A key removed from this list
/// stays in the database rather than being deleted, so revoking a capability
/// is a deliberate act and never a side effect of a deploy.
const List<PermissionDef> allPermissions = [
  // Items and stock — the core of the app.
  PermissionDef('items.view', 'Inventory', 'View items and stock levels'),
  PermissionDef('items.create', 'Inventory', 'Add new items'),
  PermissionDef('items.update', 'Inventory', 'Edit item details'),
  PermissionDef('items.delete', 'Inventory', 'Delete items'),
  PermissionDef(
    'inventory.adjust',
    'Inventory',
    'Record stock in, stock out and stocktake counts',
  ),
  PermissionDef(
    'inventory.transfer',
    'Inventory',
    'Move stock between locations',
  ),
  PermissionDef('inventory.export', 'Inventory', 'Export inventory as CSV'),
  PermissionDef(
    'categories.manage',
    'Inventory',
    'Create, rename and delete categories',
  ),
  PermissionDef('activity.view', 'Inventory', 'View the movement log'),
  PermissionDef(
    'alerts.view',
    'Inventory',
    'View low-stock and reorder alerts',
  ),

  // Purchasing.
  PermissionDef('purchase_orders.view', 'Purchasing', 'View purchase orders'),
  PermissionDef(
    'purchase_orders.create',
    'Purchasing',
    'Raise purchase orders',
  ),
  PermissionDef('purchase_orders.update', 'Purchasing', 'Edit purchase orders'),
  PermissionDef(
    'purchase_orders.delete',
    'Purchasing',
    'Delete purchase orders',
  ),
  PermissionDef('receipts.view', 'Purchasing', 'View goods receipts'),
  PermissionDef(
    'receipts.create',
    'Purchasing',
    'Receive goods against an order',
  ),

  // Sales.
  PermissionDef('sales_orders.view', 'Sales', 'View sales orders'),
  PermissionDef('sales_orders.create', 'Sales', 'Raise sales orders'),
  PermissionDef('sales_orders.update', 'Sales', 'Edit sales orders'),
  PermissionDef('sales_orders.delete', 'Sales', 'Delete sales orders'),
  PermissionDef('invoices.view', 'Sales', 'View invoices'),
  PermissionDef('invoices.create', 'Sales', 'Issue invoices'),
  PermissionDef('invoices.update', 'Sales', 'Edit invoices'),
  PermissionDef('invoices.delete', 'Sales', 'Delete invoices'),

  // Trading partners.
  PermissionDef('suppliers.view', 'Partners', 'View suppliers'),
  PermissionDef('suppliers.manage', 'Partners', 'Add and edit suppliers'),
  PermissionDef('customers.view', 'Partners', 'View customers'),
  PermissionDef('customers.manage', 'Partners', 'Add and edit customers'),

  // Reporting.
  PermissionDef('reports.view', 'Reports', 'View reports and charts'),
  PermissionDef('reports.export', 'Reports', 'Export and print reports'),

  // Administration.
  PermissionDef(
    'settings.manage',
    'Administration',
    'Change workspace settings, currency and lookups',
  ),
  PermissionDef(
    'backup.export',
    'Administration',
    'Download a full backup of the workspace',
  ),
  PermissionDef(
    'backup.restore',
    'Administration',
    'Replace the whole workspace from a backup',
  ),
  PermissionDef('users.view', 'Administration', 'View the user list'),
  PermissionDef('users.create', 'Administration', 'Invite new users'),
  PermissionDef('users.update', 'Administration', 'Edit user details'),
  PermissionDef(
    'users.disable',
    'Administration',
    'Enable and disable accounts',
  ),
  PermissionDef('users.delete', 'Administration', 'Deactivate accounts'),
  PermissionDef(
    'users.reset_password',
    'Administration',
    "Send a password reset on a user's behalf",
  ),
  PermissionDef(
    'roles.manage',
    'Administration',
    'Assign roles and grant individual permissions',
  ),
  PermissionDef(
    'sessions.revoke',
    'Administration',
    "Revoke another user's sessions",
  ),
  PermissionDef('audit_logs.view', 'Administration', 'View the audit trail'),
];

/// Convenience view of [allPermissions] by key.
final Map<String, PermissionDef> permissionsByKey = {
  for (final permission in allPermissions) permission.key: permission,
};

/// A role shipped with the system.
class SystemRole {
  const SystemRole(this.key, this.name, this.description, this.permissions);

  final String key;
  final String name;
  final String description;
  final List<String> permissions;
}

const String administratorRoleKey = 'administrator';
const String inventoryManagerRoleKey = 'inventory_manager';
const String staffRoleKey = 'staff';

/// The three roles the system seeds (§6).
///
/// Adapted to what this app actually does rather than to a generic template:
/// the manager runs purchasing and sales as well as stock, and staff can
/// record movements and receive goods — the two things a warehouse hand
/// genuinely needs — but cannot delete anything or change prices.
final List<SystemRole> systemRoles = [
  SystemRole(
    administratorRoleKey,
    'Administrator',
    'Full access, including user management and the audit trail.',
    // Deliberately derived rather than listed: a permission added above is
    // granted to administrators automatically, so the role can never drift
    // into being unable to administer something.
    allPermissions.map((p) => p.key).toList(growable: false),
  ),
  const SystemRole(
    inventoryManagerRoleKey,
    'Inventory Manager',
    'Runs stock, purchasing and sales. Cannot manage users or settings.',
    [
      'items.view',
      'items.create',
      'items.update',
      'items.delete',
      'inventory.adjust',
      'inventory.transfer',
      'inventory.export',
      'categories.manage',
      'activity.view',
      'alerts.view',
      'purchase_orders.view',
      'purchase_orders.create',
      'purchase_orders.update',
      'purchase_orders.delete',
      'receipts.view',
      'receipts.create',
      'sales_orders.view',
      'sales_orders.create',
      'sales_orders.update',
      'sales_orders.delete',
      'invoices.view',
      'invoices.create',
      'invoices.update',
      'suppliers.view',
      'suppliers.manage',
      'customers.view',
      'customers.manage',
      'reports.view',
      'reports.export',
    ],
  ),
  const SystemRole(
    staffRoleKey,
    'Staff',
    'Records stock movements and receives goods. Read-only elsewhere.',
    [
      'items.view',
      'inventory.adjust',
      'activity.view',
      'alerts.view',
      'purchase_orders.view',
      'receipts.view',
      'receipts.create',
      'sales_orders.view',
      'invoices.view',
      'suppliers.view',
      'customers.view',
      'reports.view',
    ],
  ),
];
