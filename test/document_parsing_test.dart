import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/document_parsing.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/purchase_order.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';

void main() {
  group('invoices', () {
    test('a document survives the round trip through JSON', () {
      // toJson was written for backups; these parsers are its inverse, and the
      // server sends exactly that shape. If the two drift, documents come back
      // subtly wrong rather than failing loudly — so this pins them together.
      final original = Invoice(
        id: 'inv-1',
        reference: 'INV-0007',
        customerId: 'c1',
        customerName: 'A customer',
        status: InvoiceStatus.partPaid,
        lines: const [
          InvoiceLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            sku: 'W-1',
            unit: 'box',
            quantity: 3,
            unitPrice: 4.5,
            discount: 0.5,
            costOfGoods: 2.0,
          ),
        ],
        discount: 1.25,
        taxRate: 0.075,
        taxLabel: 'VAT',
        amountPaid: 10,
        terms: 'Net 30',
        notes: 'Leave at reception',
        movesStock: true,
        issuedAt: DateTime.utc(2026, 9, 1, 10),
        dueAt: DateTime.utc(2026, 10, 1),
        createdAt: DateTime.utc(2026, 9, 1, 10),
        updatedAt: DateTime.utc(2026, 9, 2, 11),
      );

      final parsed = invoiceFromJson(original.toJson());

      expect(parsed.id, original.id);
      expect(parsed.reference, original.reference);
      expect(parsed.status, InvoiceStatus.partPaid);
      expect(parsed.taxLabel, 'VAT');
      expect(parsed.taxRate, 0.075);
      expect(parsed.amountPaid, 10);
      expect(parsed.terms, 'Net 30');
      expect(parsed.lines.single.sku, 'W-1');
      expect(parsed.lines.single.unit, 'box');
      expect(parsed.lines.single.quantity, 3);
      expect(parsed.lines.single.unitPrice, 4.5);
      expect(parsed.lines.single.costOfGoods, 2.0);
      expect(parsed.issuedAt.toUtc(), original.issuedAt.toUtc());
      expect(parsed.dueAt!.toUtc(), original.dueAt!.toUtc());
    });

    test('a proforma stays a proforma', () {
      // movesStock false is the whole difference between a document that
      // deducts stock and one that only prints, so it must not be lost.
      final proforma = Invoice(
        id: 'inv-2',
        reference: 'INV-0008',
        movesStock: false,
        issuedAt: DateTime.utc(2026, 9, 1),
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      );
      expect(invoiceFromJson(proforma.toJson()).movesStock, isFalse);
    });

    test('an absent movesStock defaults to moving stock', () {
      final parsed = invoiceFromJson({'id': 'x', 'reference': 'INV-1'});
      expect(parsed.movesStock, isTrue);
    });

    test('a malformed document degrades instead of throwing', () {
      // One bad row must not blank the screen for every other document.
      final parsed = invoiceFromJson({
        'id': 'inv-3',
        'status': 'not-a-status',
        'discount': 'nonsense',
        'lines': 'not a list',
      });
      expect(parsed.status, InvoiceStatus.open);
      expect(parsed.discount, 0);
      expect(parsed.lines, isEmpty);
    });
  });

  group('receipts', () {
    test('payment method and refunds survive', () {
      final original = Receipt(
        id: 'r1',
        reference: 'RCP-0002',
        status: ReceiptStatus.partRefunded,
        method: PaymentMethod.transfer,
        lines: const [
          ReceiptLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantity: 5,
            unitPrice: 2,
            quantityRefunded: 2,
          ),
        ],
        issuedAt: DateTime.utc(2026, 9, 3),
        refundedAt: DateTime.utc(2026, 9, 4),
        createdAt: DateTime.utc(2026, 9, 3),
        updatedAt: DateTime.utc(2026, 9, 4),
      );

      final parsed = receiptFromJson(original.toJson());

      expect(parsed.status, ReceiptStatus.partRefunded);
      expect(parsed.method, PaymentMethod.transfer);
      expect(parsed.lines.single.quantityRefunded, 2);
      expect(parsed.refundedAt!.toUtc(), original.refundedAt!.toUtc());
    });
  });

  group('orders', () {
    test('a purchase order keeps what has been received', () {
      final original = PurchaseOrder(
        id: 'po1',
        reference: 'PO-0003',
        supplierName: 'A supplier',
        status: PurchaseStatus.partial,
        lines: const [
          PurchaseOrderLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 10,
            quantityReceived: 4,
            unitCost: 1.5,
          ),
        ],
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 5),
      );

      final parsed = purchaseOrderFromJson(original.toJson());

      expect(parsed.status, PurchaseStatus.partial);
      expect(parsed.lines.single.quantityOrdered, 10);
      expect(parsed.lines.single.quantityReceived, 4);
      expect(parsed.lines.single.unitCost, 1.5);
    });

    test('a sales order keeps its price tier', () {
      final original = SalesOrder(
        id: 'so1',
        reference: 'SO-0004',
        status: SalesStatus.confirmed,
        lines: const [
          SalesOrderLine(
            id: 'l1',
            itemId: 'i1',
            itemName: 'Widget',
            quantityOrdered: 6,
            quantityFulfilled: 1,
            unitPrice: 9.99,
          ),
        ],
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 2),
      );

      final parsed = salesOrderFromJson(original.toJson());

      expect(parsed.status, SalesStatus.confirmed);
      expect(parsed.lines.single.quantityFulfilled, 1);
      expect(parsed.lines.single.unitPrice, 9.99);
    });
  });

  group('timestamps', () {
    test('a UTC instant is not shifted by the device zone', () {
      // The server always sends the trailing Z. Read without it, a device in
      // another zone lands on a different instant — and an invoice dated a day
      // out is a real problem, not a cosmetic one.
      final parsed = invoiceFromJson({
        'id': 'x',
        'reference': 'INV-9',
        'issuedAt': '2026-09-01T23:30:00.000Z',
      });
      expect(parsed.issuedAt.toUtc().day, 1);
      expect(parsed.issuedAt.toUtc().hour, 23);
    });
  });
}
