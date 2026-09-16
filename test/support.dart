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

import 'fake_inventory_server.dart';

/// A controller over a thin fake of the API.
///
/// The inventory is the server's now, so there is no local database to back a
/// controller with. What is left here is the client's own behaviour — pickers
/// learning a category, a list staying sorted, a screen rendering what it was
/// handed — and the fake exists to let a write succeed, not to be right about
/// arithmetic. Anything asserting on a quantity belongs in the server suite.
Future<InventoryController> newController() async {
  return InventoryController(
    await fakeInventoryApi(FakeInventoryServer()),
    Snapshot.empty,
  );
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
  return InventoryController(
    await fakeInventoryApi(FakeInventoryServer()),
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

/// A purchase order as it comes back from the server, for seeding.
PurchaseOrder seedPurchaseOrder({
  required String id,
  required List<PurchaseOrderLine> lines,
  String reference = 'PO-0001',
  String supplierName = '',
  PurchaseStatus status = PurchaseStatus.ordered,
}) {
  final at = DateTime.now();
  return PurchaseOrder(
    id: id,
    reference: reference,
    supplierName: supplierName,
    status: status,
    lines: lines,
    createdAt: at,
    updatedAt: at,
  );
}

/// A sales order as it comes back from the server, for seeding.
SalesOrder seedSalesOrder({
  required String id,
  required List<SalesOrderLine> lines,
  String reference = 'SO-0001',
  String customerName = '',
  SalesStatus status = SalesStatus.confirmed,
}) {
  final at = DateTime.now();
  return SalesOrder(
    id: id,
    reference: reference,
    customerName: customerName,
    status: status,
    lines: lines,
    createdAt: at,
    updatedAt: at,
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
  String notes = '',
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
    notes: notes,
    issuedAt: at,
    createdAt: at,
    updatedAt: at,
  );
}

/// A receipt as it comes back from the server, for seeding.
Receipt seedReceipt({
  required String id,
  required List<ReceiptLine> lines,
  String reference = 'RC-0001',
  String customerName = '',
  double amountPaid = 0,
  double discount = 0,
  double taxRate = 0,
  ReceiptStatus status = ReceiptStatus.issued,
  String voidReason = '',
  String? invoiceId,
  String? salesOrderId,
  DateTime? issuedAt,
}) {
  final at = issuedAt ?? DateTime.now();
  return Receipt(
    id: id,
    reference: reference,
    invoiceId: invoiceId,
    salesOrderId: salesOrderId,
    customerName: customerName,
    status: status,
    lines: lines,
    discount: discount,
    taxRate: taxRate,
    amountPaid: amountPaid,
    voidReason: voidReason,
    // A receipt against a document moves nothing: the document already did.
    movesStock: invoiceId == null && salesOrderId == null,
    issuedAt: at,
    createdAt: at,
    updatedAt: at,
  );
}

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
