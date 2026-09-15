import 'package:drift/drift.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:postgres/postgres.dart' as pg;

import 'inventory_tables.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Users,
    Roles,
    Permissions,
    UserRoles,
    RolePermissions,
    UserPermissions,
    Sessions,
    AuthTokens,
    LoginAttempts,
    AuditLogs,
    NotificationPreferences,

    // The inventory, moved here from each device's own SQLite so there is one
    // of it rather than one per browser and phone.
    Items,
    Movements,
    StockLevels,
    Suppliers,
    Customers,
    PurchaseOrders,
    PurchaseOrderLines,
    SalesOrders,
    SalesOrderLines,
    Transfers,
    TransferLines,
    Invoices,
    InvoiceLines,
    Receipts,
    ReceiptLines,
    Categories,
    Lookups,
    Preferences,
  ],
)
class AuthDatabase extends _$AuthDatabase {
  AuthDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
      await _createInventoryIndexes();
    },
    // Production already runs at 1 with live accounts in it, so the inventory
    // tables have to be added to a database that exists rather than appearing
    // in a fresh createAll. Nothing from version 1 is touched.
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        for (final table in _inventoryTables) {
          await m.createTable(table);
        }
        await _createInventoryIndexes();
      }
    },
  );

  List<TableInfo<Table, dynamic>> get _inventoryTables => [
    items,
    movements,
    stockLevels,
    suppliers,
    customers,
    purchaseOrders,
    purchaseOrderLines,
    salesOrders,
    salesOrderLines,
    transfers,
    transferLines,
    invoices,
    invoiceLines,
    receipts,
    receiptLines,
    categories,
    lookups,
    preferences,
  ];

  /// Indexes for the inventory side.
  ///
  /// Each one backs a query behind a screen the user waits on, rather than
  /// being added on principle: item lookup, a document's lines, and an item's
  /// history are the three shapes that matter.
  Future<void> _createInventoryIndexes() async {
    const statements = [
      // The two codes a scanner produces. Not unique: the client has always
      // tolerated blank and duplicated codes, and enforcing it here would
      // reject imports that used to work.
      'CREATE INDEX items_sku ON items (sku)',
      'CREATE INDEX items_barcode ON items (barcode)',
      'CREATE INDEX items_name ON items (name)',
      'CREATE INDEX items_category ON items (category)',
      'CREATE INDEX items_supplier ON items (supplier_id)',

      // An item's history, newest first. Tie-broken on id because several
      // movements are written in one transaction and share a timestamp.
      'CREATE INDEX movements_item_time ON movements (item_id, at DESC, id)',
      'CREATE INDEX movements_time ON movements (at DESC, id)',
      'CREATE INDEX movements_document ON movements (document_id)',

      'CREATE INDEX stock_levels_location ON stock_levels (location)',

      // Document lines are always read by their parent, in position order.
      'CREATE INDEX po_lines_order ON purchase_order_lines (order_id, position)',
      'CREATE INDEX so_lines_order ON sales_order_lines (order_id, position)',
      'CREATE INDEX transfer_lines_transfer ON transfer_lines '
          '(transfer_id, position)',
      'CREATE INDEX invoice_lines_invoice ON invoice_lines '
          '(invoice_id, position)',
      'CREATE INDEX receipt_lines_receipt ON receipt_lines '
          '(receipt_id, position)',

      // Document lists: filtered by status, newest first.
      'CREATE INDEX purchase_orders_status ON purchase_orders '
          '(status, created_at DESC)',
      'CREATE INDEX sales_orders_status ON sales_orders '
          '(status, created_at DESC)',
      'CREATE INDEX invoices_status ON invoices (status, issued_at DESC)',
      'CREATE INDEX receipts_status ON receipts (status, issued_at DESC)',

      // A reference is what someone quotes down the phone, so it has to be
      // unique per document type and fast to find.
      'CREATE UNIQUE INDEX purchase_orders_reference ON purchase_orders '
          '(reference)',
      'CREATE UNIQUE INDEX sales_orders_reference ON sales_orders (reference)',
      'CREATE UNIQUE INDEX invoices_reference ON invoices (reference)',
      'CREATE UNIQUE INDEX receipts_reference ON receipts (reference)',
      'CREATE UNIQUE INDEX transfers_reference ON transfers (reference)',

      'CREATE INDEX invoices_customer ON invoices (customer_id)',
      'CREATE INDEX receipts_invoice ON receipts (invoice_id)',
      'CREATE INDEX categories_position ON categories (position)',
      'CREATE INDEX lookups_kind ON lookups (kind, position)',
    ];
    for (final statement in statements) {
      await customStatement(statement);
    }
  }

  /// Indexes are created here rather than declared on the tables because two
  /// of them are partial, which drift's table-level annotation cannot express.
  Future<void> _createIndexes() async {
    const statements = [
      // Partial, so a soft-deleted account releases its address for re-use
      // while still blocking two live accounts from sharing one.
      'CREATE UNIQUE INDEX users_email_unique ON users (email) '
          'WHERE deleted_at IS NULL',
      'CREATE UNIQUE INDEX roles_key_unique ON roles (key)',

      // The hot path: every authenticated request looks a session up by its
      // access-token hash, so this index decides the API's latency floor.
      'CREATE UNIQUE INDEX sessions_access_hash ON sessions (access_token_hash)',
      'CREATE UNIQUE INDEX sessions_refresh_hash ON sessions '
          '(refresh_token_hash)',
      // Listing a user's live sessions for the security screen.
      'CREATE INDEX sessions_user_active ON sessions (user_id, revoked_at)',

      'CREATE UNIQUE INDEX auth_tokens_hash ON auth_tokens (token_hash)',
      // Redeeming a token also has to reject a second, still-unexpired token
      // of the same purpose for the same user.
      'CREATE INDEX auth_tokens_user_purpose ON auth_tokens '
          '(user_id, purpose, consumed_at)',

      // Both lockout checks: consecutive failures for an address, and the
      // per-IP throttle.
      'CREATE INDEX login_attempts_email_time ON login_attempts '
          '(email, attempted_at DESC)',
      'CREATE INDEX login_attempts_ip_time ON login_attempts '
          '(ip_address, attempted_at DESC)',
      'CREATE INDEX login_attempts_user_time ON login_attempts '
          '(user_id, attempted_at DESC)',

      // The audit screen is paged newest-first and filtered on each of these.
      'CREATE INDEX audit_logs_created ON audit_logs (created_at DESC, id)',
      'CREATE INDEX audit_logs_actor ON audit_logs (actor_id, created_at DESC)',
      'CREATE INDEX audit_logs_action ON audit_logs (action, created_at DESC)',

      'CREATE INDEX user_roles_role ON user_roles (role_id)',
    ];
    for (final statement in statements) {
      await customStatement(statement);
    }
  }
}

/// Opens the pool the server runs on.
///
/// `sslMode` is required rather than optional in production: a plaintext
/// connection would put every password hash and session token on the wire.
QueryExecutor openPostgres(String databaseUrl, {bool requireSsl = false}) {
  final uri = Uri.parse(databaseUrl);
  final userInfo = uri.userInfo.split(':');

  return PgDatabase(
    endpoint: pg.Endpoint(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.pathSegments.isEmpty ? 'postgres' : uri.pathSegments.first,
      username: userInfo.isNotEmpty && userInfo.first.isNotEmpty
          ? Uri.decodeComponent(userInfo.first)
          : null,
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
    ),
    settings: pg.ConnectionSettings(
      sslMode: requireSsl ? pg.SslMode.require : pg.SslMode.disable,
    ),
  );
}
