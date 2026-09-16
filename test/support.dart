import 'package:drift/native.dart';
import 'package:stockpile/data/database.dart';
import 'package:stockpile/data/inventory_repository.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/party.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/models/transfer.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/state/inventory_controller.dart';

/// A controller backed by a real, empty, in-memory SQLite database — the same
/// engine and schema the app uses, without touching the filesystem.
Future<InventoryController> newController({bool seeded = false}) async {
  final repo = InventoryRepository(AppDatabase(NativeDatabase.memory()));
  if (seeded) await repo.seedForTest();
  final snapshot = await repo.load();
  return InventoryController(repo, snapshot);
}

/// A controller holding exactly the state given, without going through the
/// write path to get there.
///
/// The write path is the server's now. A test that builds its fixtures by
/// calling `issueInvoice` is exercising an HTTP round trip it does not care
/// about, and asserting on arithmetic that lives on the other side of it.
/// Reporting and rendering tests want neither: their subject is "given these
/// documents, the figures read like this" and "given this state, the screen
/// shows that".
///
/// Seeding declaratively says so, and it is what lets the on-device write path
/// be deleted — nothing here needs it.
Future<InventoryController> seededController({
  List<Item> items = const [],
  List<Movement> movements = const [],
  List<Supplier> suppliers = const [],
  List<Customer> customers = const [],
  List<PurchaseOrder> purchaseOrders = const [],
  List<SalesOrder> salesOrders = const [],
  List<Receipt> receipts = const [],
  List<Invoice> invoices = const [],
  List<Transfer> transfers = const [],
  Map<String, Map<String, int>> levels = const {},
  AppSettings settings = const AppSettings(),
}) async {
  final repo = InventoryRepository(AppDatabase(NativeDatabase.memory()));
  return InventoryController(
    repo,
    Snapshot(
      items: items,
      movements: movements,
      suppliers: suppliers,
      customers: customers,
      purchaseOrders: purchaseOrders,
      salesOrders: salesOrders,
      receipts: receipts,
      invoices: invoices,
      transfers: transfers,
      levels: levels,
      settings: settings,
    ),
  );
}

/// An invoice as it comes back from the server, for seeding.
///
/// Reference and totals are the server's to decide in real use; here they are
/// simply given, because the test is about what the figures do afterwards.
Invoice seedInvoice({
  required String id,
  required List<InvoiceLine> lines,
  String reference = 'INV-0001',
  String customerName = 'A customer',
  double amountPaid = 0,
  double discount = 0,
  double taxRate = 0,
  InvoiceStatus status = InvoiceStatus.open,
  DateTime? issuedAt,
}) {
  final at = issuedAt ?? DateTime.now();
  return Invoice(
    id: id,
    reference: reference,
    customerName: customerName,
    status: status,
    lines: lines,
    discount: discount,
    taxRate: taxRate,
    amountPaid: amountPaid,
    issuedAt: at,
    createdAt: at,
    updatedAt: at,
  );
}

/// A receipt as it comes back from the server, for seeding.
Receipt seedReceipt({
  required String id,
  required List<ReceiptLine> lines,
  String reference = 'RCP-0001',
  String customerName = '',
  double amountPaid = 0,
  double discount = 0,
  double taxRate = 0,
  ReceiptStatus status = ReceiptStatus.issued,
  String? invoiceId,
  DateTime? issuedAt,
}) {
  final at = issuedAt ?? DateTime.now();
  return Receipt(
    id: id,
    reference: reference,
    invoiceId: invoiceId,
    customerName: customerName,
    status: status,
    lines: lines,
    discount: discount,
    taxRate: taxRate,
    amountPaid: amountPaid,
    movesStock: invoiceId == null,
    issuedAt: at,
    createdAt: at,
    updatedAt: at,
  );
}

/// A repository over an empty in-memory database, for testing persistence.
InventoryRepository newRepository() =>
    InventoryRepository(AppDatabase(NativeDatabase.memory()));

/// A controller over a repository the test already holds, so it can read the
/// database back afterwards.
Future<InventoryController> controllerOver(InventoryRepository repo) async =>
    InventoryController(repo, await repo.load());

Item draft({
  String name = 'Bolt',
  int quantity = 10,
  int reorderLevel = 0,
  double unitCost = 2,
  double retailerPrice = 0,
  double distributorPrice = 0,
  String category = 'Parts',
  String barcode = '',
  String sku = '',
}) {
  final now = DateTime.now();
  return Item(
    id: '',
    name: name,
    sku: sku,
    barcode: barcode,
    category: category,
    quantity: quantity,
    reorderLevel: reorderLevel,
    unitCost: unitCost,
    retailerPrice: retailerPrice,
    distributorPrice: distributorPrice,
    createdAt: now,
    updatedAt: now,
  );
}

/// The controller persists without awaiting, so tests need a moment for those
/// futures to settle before reading the database back.
Future<void> pumpWrites() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
