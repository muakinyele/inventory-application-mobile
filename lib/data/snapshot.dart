import '../models/app_settings.dart';
import '../models/invoice.dart';
import '../models/item.dart';
import '../models/movement.dart';
import '../models/party.dart';
import '../models/purchase_order.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../models/transfer.dart';

/// A snapshot of the whole catalogue, read once at startup and then kept in
/// step by the controller. Reads stay synchronous for the UI; writes go
/// through to SQLite.
class Snapshot {
  const Snapshot({
    required this.items,
    required this.movements,
    this.suppliers = const [],
    this.customers = const [],
    this.purchaseOrders = const [],
    this.salesOrders = const [],
    this.receipts = const [],
    this.invoices = const [],
    this.transfers = const [],
    this.levels = const {},
    this.sequences = const {},
    required this.settings,
  });

  final List<Item> items;
  final List<Movement> movements;
  final List<Supplier> suppliers;
  final List<Customer> customers;
  final List<PurchaseOrder> purchaseOrders;
  final List<SalesOrder> salesOrders;
  final List<Receipt> receipts;
  final List<Invoice> invoices;
  final List<Transfer> transfers;

  /// Stock broken down by location, keyed item id -> location -> quantity.
  final Map<String, Map<String, int>> levels;

  /// Persistent document counters, keyed by prefix, so a reference is never
  /// reused even after the document that had it is deleted.
  final Map<String, int> sequences;
  final AppSettings settings;

  static const empty = Snapshot(
    items: [],
    movements: [],
    suppliers: [],
    customers: [],
    purchaseOrders: [],
    salesOrders: [],
    receipts: [],
    invoices: [],
    transfers: [],
    levels: {},
    settings: AppSettings(),
  );
}

/// The document collections that are fetched on demand rather than at sign-in.
///
/// Named as a set so a screen can ask for exactly what it shows: the sales
/// order detail needs receipts and invoices, the receipts page needs only
/// receipts, and neither should wait for the other's.
enum DocumentSet { invoices, receipts, purchaseOrders, salesOrders, transfers }
