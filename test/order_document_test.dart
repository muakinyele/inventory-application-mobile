import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/order_document.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/sales_order.dart';

const _settings = AppSettings(
  companyName: 'Chedra Olympas',
  currency: 'NGN',
  companyPhone: '+234 802 123 4567',
);

PurchaseOrder _purchase({
  PurchaseStatus status = PurchaseStatus.ordered,
  DateTime? orderedAt,
}) => PurchaseOrder(
  id: 'po1',
  reference: 'PO-0007',
  supplierName: 'Nexa Components',
  status: status,
  orderedAt: orderedAt,
  expectedAt: DateTime.utc(2026, 10, 1),
  notes: 'Deliver to the side gate.',
  lines: const [
    PurchaseOrderLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantityOrdered: 100,
      quantityReceived: 40,
      unitCost: 25,
    ),
  ],
  createdAt: DateTime.utc(2026, 9, 20),
  updatedAt: DateTime.utc(2026, 9, 20),
);

SalesOrder _sale() => SalesOrder(
  id: 'so1',
  reference: 'SO-0021',
  customerName: 'Ada Nwosu',
  status: SalesStatus.confirmed,
  confirmedAt: DateTime.utc(2026, 9, 22),
  lines: const [
    SalesOrderLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      quantityOrdered: 10,
      quantityFulfilled: 10,
      unitPrice: 60,
    ),
  ],
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
);

void main() {
  // The PDF embeds the app's own fonts, which are loaded through the asset
  // bundle — so a render is not a pure function and needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a purchase order as a document', () {
    test('it carries the supplier, the reference and the totals', () {
      final data = OrderDocumentData.fromPurchase(_purchase());

      expect(data.kind, 'PURCHASE ORDER');
      expect(data.partyLabel, 'Supplier');
      expect(data.partyName, 'Nexa Components');
      expect(data.reference, 'PO-0007');
      expect(data.total, 100 * 25);
      expect(data.settledLabel, 'RECEIVED');
      expect(data.dueLabel, 'Expected');
    });

    test('what is still outstanding is worked out per line', () {
      final data = OrderDocumentData.fromPurchase(_purchase());
      expect(data.lines.single.outstanding, 60);
    });

    test('a draft with no ordered date still has a date on it', () {
      // Printing nothing where a date belongs looks like a rendering fault.
      final data = OrderDocumentData.fromPurchase(
        _purchase(status: PurchaseStatus.draft),
      );
      expect(data.issuedAt, DateTime.utc(2026, 9, 20));
    });

    test('an unassigned supplier says so rather than printing blank', () {
      final order = PurchaseOrder(
        id: 'po2',
        reference: 'PO-0008',
        supplierName: '',
        status: PurchaseStatus.draft,
        createdAt: DateTime.utc(2026, 9, 20),
        updatedAt: DateTime.utc(2026, 9, 20),
      );
      expect(OrderDocumentData.fromPurchase(order).partyName, 'Not assigned');
    });

    test('it renders to a real PDF', () async {
      final bytes = await OrderDocument(
        OrderDocumentData.fromPurchase(_purchase()),
        _settings,
      ).toPdf();

      expect(bytes.length, greaterThan(1000));
      // %PDF-
      expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    });

    test('the filename carries the reference and the date', () {
      final doc = OrderDocument(
        OrderDocumentData.fromPurchase(
          _purchase(orderedAt: DateTime.utc(2026, 9, 25)),
        ),
        _settings,
      );
      expect(doc.filename('pdf'), 'PO-0007-20260925.pdf');
    });
  });

  group('a sales order as a document', () {
    test('the nouns swap, the layout does not', () {
      final data = OrderDocumentData.fromSales(_sale());

      expect(data.kind, 'SALES ORDER');
      expect(data.partyLabel, 'Customer');
      expect(data.partyName, 'Ada Nwosu');
      expect(data.settledLabel, 'SENT');
      expect(data.dueLabel, 'Due');
      expect(data.total, 10 * 60);
    });

    test('a walk-in sale is named rather than left blank', () {
      final order = SalesOrder(
        id: 'so2',
        reference: 'SO-0022',
        customerName: '',
        status: SalesStatus.draft,
        createdAt: DateTime.utc(2026, 9, 22),
        updatedAt: DateTime.utc(2026, 9, 22),
      );
      expect(OrderDocumentData.fromSales(order).partyName, 'Walk-in');
    });

    test('it renders to a real PDF', () async {
      final bytes = await OrderDocument(
        OrderDocumentData.fromSales(_sale()),
        _settings,
      ).toPdf();

      expect(bytes.length, greaterThan(1000));
      expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    });

    test('an order with no lines still renders', () async {
      // A draft is shared to be discussed before it has anything on it.
      final order = SalesOrder(
        id: 'so3',
        reference: 'SO-0023',
        customerName: 'Ada Nwosu',
        status: SalesStatus.draft,
        createdAt: DateTime.utc(2026, 9, 22),
        updatedAt: DateTime.utc(2026, 9, 22),
      );

      final bytes = await OrderDocument(
        OrderDocumentData.fromSales(order),
        _settings,
      ).toPdf();

      expect(bytes.length, greaterThan(1000));
    });
  });
}
