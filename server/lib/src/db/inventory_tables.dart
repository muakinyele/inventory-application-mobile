import 'package:drift/drift.dart';

/// The inventory tables, ported from the client's on-device schema.
///
/// Until now every one of these lived in drift/SQLite on each device, so the
/// web build and a phone held entirely separate stock. They move here so there
/// is one inventory, shared by every signed-in user.
///
/// Conventions follow `tables.dart`: application-generated text ids minted
/// before the insert, and every timestamp stored UTC.
///
/// Denormalised names (`itemName`, `supplierName`, `customerName`) are kept
/// deliberately. A movement or a document line has to remain readable after
/// the row it points at is renamed or deleted — history that rewrites itself
/// is not history.

/// A thing held in stock.
class Items extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get sku => text().withDefault(const Constant(''))();
  TextColumn get barcode => text().withDefault(const Constant(''))();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get location => text().withDefault(const Constant(''))();

  /// The total across every location. Kept in step with [StockLevels] inside
  /// the same transaction that writes a movement, so the two cannot drift.
  IntColumn get quantity => integer().withDefault(const Constant(0))();

  IntColumn get reorderLevel => integer().withDefault(const Constant(0))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get unitCost => real().withDefault(const Constant(0))();
  RealColumn get retailerPrice => real().withDefault(const Constant(0))();
  RealColumn get distributorPrice => real().withDefault(const Constant(0))();

  /// Free-text supplier name, for items imported from a sheet with no matching
  /// supplier record.
  TextColumn get supplier => text().withDefault(const Constant(''))();

  /// Set once linked to a [Suppliers] row, which supersedes the name above.
  TextColumn get supplierId => text().nullable()();

  /// Stock units in one purchase pack — a carton of 24, say. Stock is always
  /// counted in single units; this only affects buying.
  IntColumn get unitsPerPack => integer().withDefault(const Constant(1))();

  TextColumn get notes => text().withDefault(const Constant(''))();

  /// Base64 of a downscaled photo. Null for most items.
  TextColumn get photo => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every change to a quantity, append-only.
class Movements extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text()();

  /// Denormalised so history survives deletion of the item it refers to.
  TextColumn get itemName => text()();

  TextColumn get kind => text()();
  IntColumn get before => integer()();
  IntColumn get after => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// Who recorded it. Now a user id rather than the blank it used to be on
  /// device, because on a shared inventory "who" is the point.
  TextColumn get actor => text().withDefault(const Constant(''))();

  /// Set when the movement came from a document rather than a manual
  /// adjustment, so a receipt or a sale can be traced back.
  TextColumn get documentId => text().nullable()();

  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Quantity per bin. The authority on where stock physically is; [Items.quantity]
/// is the sum of these.
class StockLevels extends Table {
  TextColumn get itemId => text()();

  /// Never blank — stock with no location recorded sits in 'Unassigned' so it
  /// is still countable.
  TextColumn get location => text()();

  IntColumn get quantity => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {itemId, location};
}

class Suppliers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get contactName => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();
  IntColumn get leadTimeDays => integer().withDefault(const Constant(0))();
  TextColumn get paymentTerms => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  /// Archived rather than deleted: documents reference suppliers, and those
  /// references have to stay resolvable.
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get contactName => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get priceTier => text().withDefault(const Constant('retailer'))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class PurchaseOrders extends Table {
  TextColumn get id => text()();
  TextColumn get reference => text()();
  TextColumn get supplierId => text().nullable()();
  TextColumn get supplierName => text().withDefault(const Constant(''))();
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

class SalesOrders extends Table {
  TextColumn get id => text()();
  TextColumn get reference => text()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text().withDefault(const Constant(''))();
  TextColumn get priceTier => text().withDefault(const Constant('retailer'))();
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

class SalesOrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  IntColumn get quantityOrdered => integer()();
  IntColumn get quantityFulfilled => integer().withDefault(const Constant(0))();
  RealColumn get unitPrice => real().withDefault(const Constant(0))();

  /// Captured at fulfilment, not read from the item later: profit reporting
  /// has to reflect what the stock cost at the time it left.
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Transfers extends Table {
  TextColumn get id => text()();
  TextColumn get reference => text()();
  TextColumn get fromLocation => text()();
  TextColumn get toLocation => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get movedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

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

class Invoices extends Table {
  TextColumn get id => text()();
  TextColumn get reference => text()();
  TextColumn get salesOrderId => text().nullable()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('open'))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  TextColumn get taxLabel => text().withDefault(const Constant('Tax'))();
  RealColumn get amountPaid => real().withDefault(const Constant(0))();
  TextColumn get terms => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  /// False for a proforma: it prints like an invoice but must not move stock.
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
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Receipts extends Table {
  TextColumn get id => text()();
  TextColumn get reference => text()();
  TextColumn get salesOrderId => text().nullable()();
  TextColumn get invoiceId => text().nullable()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('issued'))();
  TextColumn get method => text().withDefault(const Constant('cash'))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  TextColumn get taxLabel => text().withDefault(const Constant('Tax'))();
  RealColumn get amountPaid => real().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get cashier => text().withDefault(const Constant(''))();
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

class ReceiptLines extends Table {
  TextColumn get id => text()();
  TextColumn get receiptId => text()();
  TextColumn get itemId => text()();
  TextColumn get itemName => text()();
  TextColumn get sku => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get quantity => integer()();
  RealColumn get unitPrice => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  IntColumn get quantityRefunded => integer().withDefault(const Constant(0))();
  RealColumn get costOfGoods => real().withDefault(const Constant(0))();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Item categories, with a colour swatch and a manual order.
class Categories extends Table {
  TextColumn get name => text()();
  IntColumn get swatchIndex => integer()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {name};
}

/// Small user-editable value lists — units, locations, payment methods.
class Lookups extends Table {
  TextColumn get kind => text()();
  TextColumn get value => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {kind, value};
}

/// Workspace settings: company name, invoice numbering, the logo.
///
/// One row per key, shared by everyone — these were per-device and are now
/// the workspace's, which is the point of the move.
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
