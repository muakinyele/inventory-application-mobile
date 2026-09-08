import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// One row per catalogue item.
///
/// Ids are the app's own string ids rather than autoincrement integers, so an
/// item keeps its identity across an export/import round trip.
@DataClassName('ItemRow')
class Items extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get sku => text().withDefault(const Constant(''))();
  TextColumn get barcode => text().withDefault(const Constant(''))();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get location => text().withDefault(const Constant(''))();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  IntColumn get reorderLevel => integer().withDefault(const Constant(0))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get unitCost => real().withDefault(const Constant(0))();
  RealColumn get retailerPrice => real().withDefault(const Constant(0))();
  RealColumn get distributorPrice => real().withDefault(const Constant(0))();

  /// Free-text supplier name, kept for items imported from a sheet that has
  /// no matching supplier record.
  TextColumn get supplier => text().withDefault(const Constant(''))();

  /// Set once the item is linked to a [Suppliers] record, which supersedes
  /// the free-text name above.
  TextColumn get supplierId => text().nullable()();

  /// How many stock units are in one purchase pack — a carton of 24, say.
  /// Stock is always counted in single units; this only affects buying.
  IntColumn get unitsPerPack => integer().withDefault(const Constant(1))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  /// Base64 of a downscaled photo. Nullable — most items have none.
  TextColumn get photo => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The stock ledger. Rows are never updated — only inserted and trimmed — so
/// history stays an append-only record of what happened.
@DataClassName('MovementRow')
class Movements extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text()();

  /// Denormalised so history survives deletion of the item it refers to.
  TextColumn get itemName => text()();

  TextColumn get kind => text()();
  IntColumn get before => integer()();
  IntColumn get after => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// Who recorded it. Blank on rows written before the app had users.
  TextColumn get actor => text().withDefault(const Constant(''))();

  /// Set when the movement came from a document rather than a manual
  /// adjustment, so a receipt or a sale can be traced back.
  TextColumn get documentId => text().nullable()();

  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Who the stock is bought from.
@DataClassName('SupplierRow')
class Suppliers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get contactName => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();

  /// Working days between placing an order and receiving it, used to work out
  /// when a reorder has to be raised.
  IntColumn get leadTimeDays => integer().withDefault(const Constant(0))();

  TextColumn get paymentTerms => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Who the stock is sold to, and at which of the two price tiers.
@DataClassName('CustomerRow')
class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get contactName => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();

  /// 'retailer' or 'distributor' — decides which price a sale defaults to.
  TextColumn get priceTier => text().withDefault(const Constant('retailer'))();

  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A buying document. Stock only moves when a line is received, so an order
/// can be raised, edited and cancelled without ever touching stock levels.
@DataClassName('PurchaseOrderRow')
class PurchaseOrders extends Table {
  TextColumn get id => text()();

  /// Human reference such as PO-0007, unique and never reused.
  TextColumn get reference => text()();

  TextColumn get supplierId => text().nullable()();

  /// Denormalised so a closed order still reads correctly after the supplier
  /// record is deleted.
  TextColumn get supplierName => text().withDefault(const Constant(''))();

  /// draft | ordered | partial | received | cancelled
  TextColumn get status => text().withDefault(const Constant('draft'))();

  DateTimeColumn get orderedAt => dateTime().nullable()();
  DateTimeColumn get expectedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One item on a purchase order. Quantities are always in stock units, even
/// when the buyer entered packs.
@DataClassName('PurchaseOrderLineRow')
class PurchaseOrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  IntColumn get quantityOrdered => integer()();
  IntColumn get quantityReceived => integer().withDefault(const Constant(0))();
  RealColumn get unitCost => real().withDefault(const Constant(0))();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A selling document. Stock only moves when a line is sent, so a quote can
/// be raised, edited and cancelled without ever touching stock levels.
@DataClassName('SalesOrderRow')
class SalesOrders extends Table {
  TextColumn get id => text()();

  /// Human reference such as SO-0007, unique and never reused.
  TextColumn get reference => text()();

  TextColumn get customerId => text().nullable()();

  /// Denormalised so a closed sale still reads correctly after the customer
  /// record is deleted.
  TextColumn get customerName => text().withDefault(const Constant(''))();

  /// 'retailer' or 'distributor' — the tier the lines were quoted at, frozen
  /// on the document so re-tiering a customer never rewrites old sales.
  TextColumn get priceTier => text().withDefault(const Constant('retailer'))();

  /// draft | confirmed | partial | fulfilled | cancelled
  TextColumn get status => text().withDefault(const Constant('draft'))();

  DateTimeColumn get confirmedAt => dateTime().nullable()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One item on a sales order.
@DataClassName('SalesOrderLineRow')
class SalesOrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  IntColumn get quantityOrdered => integer()();
  IntColumn get quantityFulfilled => integer().withDefault(const Constant(0))();
  RealColumn get unitPrice => real().withDefault(const Constant(0))();

  /// What the stock sent so far cost, banked at the moment it left, so margin
  /// survives later movements in the item's average cost.
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Where an item's stock physically is. One row per item per location; the
/// rows for an item always sum to that item's [Items.quantity], which stays
/// the authoritative total so every screen that only cares about "how many"
/// keeps reading one number.
@DataClassName('StockLevelRow')
class StockLevels extends Table {
  TextColumn get itemId => text()();

  /// The bin. Never blank — stock with no location recorded sits in
  /// 'Unassigned' so it is still countable.
  TextColumn get location => text()();

  IntColumn get quantity => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {itemId, location};
}

/// A movement of stock between two locations. Transfers apply the moment they
/// are saved — there is no draft and no in-transit state — so a transfer is a
/// record of something that has already happened and is never edited. To undo
/// one, raise the opposite transfer.
@DataClassName('TransferRow')
class Transfers extends Table {
  TextColumn get id => text()();

  /// Human reference such as TR-0007, unique and never reused.
  TextColumn get reference => text()();

  TextColumn get fromLocation => text()();
  TextColumn get toLocation => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get movedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One item on a transfer, in stock units.
@DataClassName('TransferLineRow')
class TransferLines extends Table {
  TextColumn get id => text()();
  TextColumn get transferId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  IntColumn get quantity => integer()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Categories are referenced by name on [Items]; this table carries the
/// ordering and the chosen swatch.
@DataClassName('CategoryRow')
class Categories extends Table {
  TextColumn get name => text()();
  IntColumn get swatchIndex => integer().nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {name};
}

/// Simple key/value rows for locations and units, which are just ordered lists.
@DataClassName('LookupRow')
class Lookups extends Table {
  TextColumn get kind => text()();
  TextColumn get value => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {kind, value};
}

/// Single-row-per-key application settings.
@DataClassName('PreferenceRow')
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// A proof-of-sale document — what the customer was handed at the counter.
///
/// Never edited once written: a mistake is voided and re-raised, and goods
/// coming back are refunded, so the row always reads as what actually
/// happened. Money is stored as it was charged, tax rate included, so
/// re-printing an old receipt years later reproduces it exactly.
@DataClassName('ReceiptRow')
class Receipts extends Table {
  TextColumn get id => text()();

  /// Human reference such as RC-0007, unique and never reused.
  TextColumn get reference => text()();

  /// Set when the receipt settles a sales order rather than standing alone.
  TextColumn get salesOrderId => text().nullable()();

  /// Set when the receipt is a payment against a credit sale. Such a receipt
  /// never moves stock — the invoice already did — and its total is the
  /// payment, not a fresh sale, so reporting counts it once only.
  TextColumn get invoiceId => text().nullable()();

  TextColumn get customerId => text().nullable()();

  /// Denormalised so an old receipt still prints with a name on it after the
  /// customer record is deleted.
  TextColumn get customerName => text().withDefault(const Constant(''))();

  /// issued | partRefunded | refunded | voided
  TextColumn get status => text().withDefault(const Constant('issued'))();

  /// cash | card | transfer | mobile | credit
  TextColumn get method => text().withDefault(const Constant('cash'))();

  /// Money off the whole bill, on top of any per-line discounts.
  RealColumn get discount => real().withDefault(const Constant(0))();

  /// Frozen at the moment of issue, so changing the rate in settings never
  /// rewrites what a customer was actually charged.
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  TextColumn get taxLabel => text().withDefault(const Constant('Tax'))();

  RealColumn get amountPaid => real().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get cashier => text().withDefault(const Constant(''))();

  /// Whether issuing this receipt is what took the stock off the shelf. False
  /// for one raised against a sales order, whose despatch already moved it.
  BoolColumn get movesStock => boolean().withDefault(const Constant(true))();

  DateTimeColumn get issuedAt => dateTime()();
  DateTimeColumn get refundedAt => dateTime().nullable()();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  TextColumn get voidReason => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One item on a receipt, priced as it was sold.
@DataClassName('ReceiptLineRow')
class ReceiptLines extends Table {
  TextColumn get id => text()();
  TextColumn get receiptId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  TextColumn get sku => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get quantity => integer()();
  RealColumn get unitPrice => real().withDefault(const Constant(0))();

  /// Money off this line, as an amount rather than a rate.
  RealColumn get discount => real().withDefault(const Constant(0))();

  IntColumn get quantityRefunded => integer().withDefault(const Constant(0))();

  /// What the goods cost, banked when they left the shelf.
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A credit sale: goods handed over now, money owed later.
///
/// The counterpart to [Receipts] and deliberately the same shape — the two
/// differ in when payment arrives, not in what was sold. Payments against it
/// are receipts carrying this invoice's id, so the running balance and the
/// customer's proof of each payment stay the same set of facts.
@DataClassName('InvoiceRow')
class Invoices extends Table {
  TextColumn get id => text()();

  /// Human reference such as INV-0007, unique and never reused.
  TextColumn get reference => text()();

  /// Set when the invoice bills a sales order rather than standing alone.
  TextColumn get salesOrderId => text().nullable()();

  TextColumn get customerId => text().nullable()();

  /// Denormalised so an old invoice still prints with a name on it after the
  /// customer record is deleted.
  TextColumn get customerName => text().withDefault(const Constant(''))();

  /// open | partPaid | paid | cancelled
  TextColumn get status => text().withDefault(const Constant('open'))();

  /// Money off the whole bill, on top of any per-line discounts.
  RealColumn get discount => real().withDefault(const Constant(0))();

  /// Frozen at issue, so changing the rate in settings never rewrites what a
  /// customer was already billed.
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  TextColumn get taxLabel => text().withDefault(const Constant('Tax'))();

  /// Kept in step by the controller as payments land, so a screen can read a
  /// balance without gathering every receipt first.
  RealColumn get amountPaid => real().withDefault(const Constant(0))();

  /// Free text such as "30 days net".
  TextColumn get terms => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  /// Whether issuing this invoice is what took the stock off the shelf. False
  /// for one billing a sales order, whose despatch already moved it.
  BoolColumn get movesStock => boolean().withDefault(const Constant(true))();

  DateTimeColumn get issuedAt => dateTime()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get cancelledReason => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One item on an invoice, priced as it was sold.
@DataClassName('InvoiceLineRow')
class InvoiceLines extends Table {
  TextColumn get id => text()();
  TextColumn get invoiceId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  TextColumn get sku => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get quantity => integer()();
  RealColumn get unitPrice => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();

  /// What the goods cost, banked when they left the shelf.
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Items,
    Movements,
    Suppliers,
    Customers,
    PurchaseOrders,
    PurchaseOrderLines,
    SalesOrders,
    SalesOrderLines,
    Receipts,
    ReceiptLines,
    Invoices,
    InvoiceLines,
    StockLevels,
    Transfers,
    TransferLines,
    Categories,
    Lookups,
    Preferences,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Pass an [executor] to run against something other than the on-device
  /// database — tests supply an in-memory one. Nothing here may import
  /// `drift/native.dart`: that pulls in `dart:ffi`, which the web build
  /// cannot compile.
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 9;

  /// Store timestamps as ISO-8601 text rather than drift's default Unix
  /// *seconds*. Several movements are routinely recorded inside one second —
  /// a stocktake, an undo, a CSV import — and at second precision they tie,
  /// which makes ledger order non-deterministic and breaks trimming by age.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Driven by the columns that are actually present rather than by the
      // recorded version alone. A migration can be left half-applied — the
      // schema change committed but `user_version` not persisted — and a
      // blind `RENAME COLUMN` then fails on the next launch, taking the whole
      // app down with it.
      final columns = await _columnNames('items');

      if (!columns.contains('distributor_price')) {
        if (columns.contains('unit_price')) {
          // v1 held a single `unit_price`, and that figure was the
          // distributor price, so it keeps its meaning under the new name.
          await m.renameColumn(items, 'unit_price', items.distributorPrice);
        } else {
          await m.addColumn(items, items.distributorPrice);
        }
      }
      if (!columns.contains('retailer_price')) {
        await m.addColumn(items, items.retailerPrice);
      }

      if (from < 9) {
        if (!await _tableExists('invoices')) await m.createTable(invoices);
        if (!await _tableExists('invoice_lines')) {
          await m.createTable(invoiceLines);
        }
        // Added to a table that may already exist from v8, so the column is
        // checked for rather than assumed missing.
        if (await _tableExists('receipts')) {
          final columns = await _columnNames('receipts');
          if (!columns.contains('invoice_id')) {
            await m.addColumn(receipts, receipts.invoiceId);
          }
        }
      }
      if (from < 8) {
        if (!await _tableExists('receipts')) await m.createTable(receipts);
        if (!await _tableExists('receipt_lines')) {
          await m.createTable(receiptLines);
        }
      }
      if (from < 7) {
        if (!await _tableExists('stock_levels')) {
          await m.createTable(stockLevels);
          // Everything held so far sits wherever its item says it is, so no
          // stock is stranded when the breakdown starts being tracked.
          await customStatement(
            "INSERT INTO stock_levels (item_id, location, quantity) "
            "SELECT id, CASE WHEN TRIM(location) = '' THEN 'Unassigned' "
            "ELSE location END, quantity FROM items WHERE quantity <> 0",
          );
        }
        if (!await _tableExists('transfers')) await m.createTable(transfers);
        if (!await _tableExists('transfer_lines')) {
          await m.createTable(transferLines);
        }
      }
      if (from < 6) {
        if (!await _tableExists('sales_orders')) {
          await m.createTable(salesOrders);
        }
        if (!await _tableExists('sales_order_lines')) {
          await m.createTable(salesOrderLines);
        }
      }
      if (from < 5) {
        if (!await _tableExists('purchase_orders')) {
          await m.createTable(purchaseOrders);
        }
        if (!await _tableExists('purchase_order_lines')) {
          await m.createTable(purchaseOrderLines);
        }
      }
      if (from < 4) {
        if (!await _tableExists('suppliers')) await m.createTable(suppliers);
        if (!await _tableExists('customers')) await m.createTable(customers);

        final itemColumns = await _columnNames('items');
        if (!itemColumns.contains('supplier_id')) {
          await m.addColumn(items, items.supplierId);
        }
        if (!itemColumns.contains('units_per_pack')) {
          await m.addColumn(items, items.unitsPerPack);
        }

        final movementColumns = await _columnNames('movements');
        if (!movementColumns.contains('actor')) {
          await m.addColumn(movements, movements.actor);
        }
        if (!movementColumns.contains('document_id')) {
          await m.addColumn(movements, movements.documentId);
        }
      }
      if (from < 3) {
        // Back-fill a retailer price 20% above the distributor figure, to
        // whole units. Only rows that have a distributor price and no
        // retailer price are touched, so a deliberate entry — including a
        // deliberate zero on something that is not resold — is never
        // overwritten.
        await customStatement(
          'UPDATE items '
          'SET retailer_price = ROUND(distributor_price * 1.2) '
          'WHERE retailer_price = 0 AND distributor_price > 0',
        );
      }
    },
  );

  Future<Set<String>> _columnNames(String table) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return {for (final row in rows) row.read<String>('name')};
  }

  Future<bool> _tableExists(String table) async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(table)],
    ).get();
    return rows.isNotEmpty;
  }

  static QueryExecutor _open() => driftDatabase(
    name: 'stockpile',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}
