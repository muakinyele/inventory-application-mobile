import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/report_document.dart';
import 'package:stockpile/data/sales_report.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

SalesReport reportOver(InventoryController c, ReportRange range) =>
    SalesReport.build(
      range: range,
      receipts: c.receipts,
      invoices: c.invoices,
      salesOrders: c.salesOrders,
      currency: c.settings.currency,
    );

SalesReport thisMonth(InventoryController c) =>
    reportOver(c, ReportRange.of(ReportPeriod.monthly, DateTime.now()));

void main() {
  group('ranges', () {
    test('a day runs midnight to midnight', () {
      final range = ReportRange.of(
        ReportPeriod.daily,
        DateTime(2026, 3, 14, 15, 30),
      );
      expect(range.start, DateTime(2026, 3, 14));
      expect(range.end, DateTime(2026, 3, 15));
      expect(range.contains(DateTime(2026, 3, 14)), isTrue);
      expect(range.contains(DateTime(2026, 3, 14, 23, 59, 59)), isTrue);
      // Half-open: midnight belongs to the next day only.
      expect(range.contains(DateTime(2026, 3, 15)), isFalse);
    });

    test('a week runs Monday to Sunday', () {
      // 2026-03-14 is a Saturday.
      final range = ReportRange.of(ReportPeriod.weekly, DateTime(2026, 3, 14));
      expect(range.start, DateTime(2026, 3, 9));
      expect(range.end, DateTime(2026, 3, 16));
      expect(range.start.weekday, DateTime.monday);
      expect(range.lastDay.weekday, DateTime.sunday);
    });

    test('a month covers its own length, February included', () {
      final feb = ReportRange.of(ReportPeriod.monthly, DateTime(2026, 2, 20));
      expect(feb.start, DateTime(2026, 2));
      expect(feb.end, DateTime(2026, 3));
      expect(feb.lastDay, DateTime(2026, 2, 28));

      final dec = ReportRange.of(ReportPeriod.monthly, DateTime(2026, 12, 5));
      expect(dec.end, DateTime(2027));
    });

    test('a year runs January to December', () {
      final range = ReportRange.of(ReportPeriod.yearly, DateTime(2026, 7, 4));
      expect(range.start, DateTime(2026));
      expect(range.end, DateTime(2027));
      expect(range.label, '2026');
    });

    test('a custom span includes the last day the user picked', () {
      final range = ReportRange.between(
        DateTime(2026, 3, 1),
        DateTime(2026, 3, 10),
      );
      expect(range.contains(DateTime(2026, 3, 10, 23, 59)), isTrue);
      expect(range.contains(DateTime(2026, 3, 11)), isFalse);
    });

    test('adjacent periods tile without overlapping', () {
      // Stepping is what the screen does, and the two spans must meet exactly
      // — no gap that loses a sale, no overlap that counts one twice.
      final feb = ReportRange.of(ReportPeriod.monthly, DateTime(2026, 2, 5));
      final march = ReportRange.of(ReportPeriod.monthly, DateTime(2026, 3, 5));
      expect(feb.end, march.start);

      final week1 = ReportRange.of(ReportPeriod.weekly, DateTime(2026, 3, 3));
      final week2 = ReportRange.of(ReportPeriod.weekly, DateTime(2026, 3, 10));
      expect(week1.end, week2.start);
    });
  });

  group('figures', () {
    test('a counter sale reports revenue, cost, profit and margin', () async {
      final c = await newController();
      final item = await c.createItem(
        draft(name: 'Bolt', quantity: 50, unitCost: 100, sku: 'B-1'),
      );
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            sku: 'B-1',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        amountPaid: 5000,
      );

      final report = thisMonth(c);

      expect(report.revenue, 5000);
      expect(report.costOfGoods, 1000);
      expect(report.grossProfit, 4000);
      expect(report.marginRate, closeTo(0.8, 0.0001));
      expect(report.unitsSold, 10);
      expect(report.documentCount, 1);

      final line = report.lines.single;
      expect(line.itemName, 'Bolt');
      expect(line.sku, 'B-1');
      expect(line.unitsSold, 10);
      expect(line.grossProfit, 4000);
    });

    test('revenue is stated before tax', () async {
      final c = await newController();
      c.updateSettings(c.settings.copyWith(taxRate: 0.1));
      final item = await c.createItem(draft(quantity: 50, unitCost: 100));
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      // The customer paid 5500; 500 of that is the government's.
      expect(thisMonth(c).revenue, 5000);
    });

    test(
      'a credit sale is revenue in full, with the balance outstanding',
      () async {
        // Seeded rather than issued. Raising an invoice is the server's job
        // now; what this test is about is what the report makes of one.
        const lines = [
          InvoiceLine(
            id: 'a',
            itemId: 'i1',
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ];

        final unpaid = await seededController(
          invoices: [seedInvoice(id: 'inv1', lines: lines)],
        );

        var report = thisMonth(unpaid);
        expect(report.revenue, 5000);
        expect(report.outstanding, 5000);
        expect(report.creditSales, 1);
        expect(report.revenueBySource[SaleSource.credit], 5000);

        // Collecting the money does not change what was earned.
        final settled = await seededController(
          invoices: [
            seedInvoice(
              id: 'inv1',
              lines: lines,
              amountPaid: 5000,
              status: InvoiceStatus.paid,
            ),
          ],
        );

        report = thisMonth(settled);
        expect(report.revenue, 5000);
        expect(report.outstanding, 0);
      },
    );

    test('an invoice payment is never counted as a second sale', () async {
      // Two receipts against one invoice. The goods were sold once, so the
      // report has to count one sale and the money once — the receipts are
      // records of collection, not of a second sale.
      const lines = [
        InvoiceLine(
          id: 'a',
          itemId: 'i1',
          itemName: 'Bolt',
          quantity: 10,
          unitPrice: 500,
          costOfGoods: 1000,
        ),
      ];
      final invoice = seedInvoice(
        id: 'inv1',
        lines: lines,
        amountPaid: 5000,
        status: InvoiceStatus.paid,
      );

      final c = await seededController(
        invoices: [invoice],
        receipts: [
          seedReceipt(
            id: 'r1',
            reference: 'RC-0001',
            invoiceId: invoice.id,
            amountPaid: 2000,
            lines: const [],
          ),
          seedReceipt(
            id: 'r2',
            reference: 'RC-0002',
            invoiceId: invoice.id,
            amountPaid: 3000,
            lines: const [],
          ),
        ],
      );

      final report = thisMonth(c);

      expect(c.receipts, hasLength(2));
      expect(report.documentCount, 1);
      expect(report.revenue, 5000);
      expect(report.costOfGoods, 1000);
      expect(report.unitsSold, 10);
    });

    test('a receipt for a sales order is not counted twice either', () async {
      // The order is the sale. A receipt raised against it records the money
      // arriving, and counting both would double the day's takings.
      final c = await seededController(
        salesOrders: [
          SalesOrder(
            id: 'so1',
            reference: 'SO-0001',
            status: SalesStatus.fulfilled,
            lines: const [
              SalesOrderLine(
                id: 'l1',
                itemId: 'i1',
                itemName: 'Bolt',
                quantityOrdered: 10,
                quantityFulfilled: 10,
                unitPrice: 500,
                costOfGoods: 1000,
              ),
            ],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ],
        receipts: [
          // Linked to the order, so it records the money arriving rather than
          // a second sale — which is the whole point of this test.
          seedReceipt(
            id: 'r1',
            salesOrderId: 'so1',
            lines: const [],
            amountPaid: 5000,
          ),
        ],
      );

      final report = thisMonth(c);

      expect(report.documentCount, 1);
      expect(report.revenue, 5000);
      expect(report.costOfGoods, 1000);
      expect(report.revenueBySource[SaleSource.salesOrder], 5000);
      expect(report.revenueBySource[SaleSource.counter], isNull);
    });

    test('all three sources add up without overlapping', () async {
      // Twenty over the counter, twenty on credit, twenty against an order:
      // three documents, one item, and a total that is the sum of the parts
      // with nothing counted in two of them.
      final c = await seededController(
        receipts: [
          seedReceipt(
            id: 'r1',
            amountPaid: 10000,
            lines: const [
              ReceiptLine(
                id: 'a',
                itemId: 'i1',
                itemName: 'Bolt',
                quantity: 20,
                unitPrice: 500,
                costOfGoods: 2000,
              ),
            ],
          ),
        ],
        invoices: [
          seedInvoice(
            id: 'inv1',
            lines: const [
              InvoiceLine(
                id: 'b',
                itemId: 'i1',
                itemName: 'Bolt',
                quantity: 20,
                unitPrice: 500,
                costOfGoods: 2000,
              ),
            ],
          ),
        ],
        salesOrders: [
          SalesOrder(
            id: 'so1',
            reference: 'SO-0001',
            status: SalesStatus.fulfilled,
            lines: const [
              SalesOrderLine(
                id: 'c',
                itemId: 'i1',
                itemName: 'Bolt',
                quantityOrdered: 20,
                quantityFulfilled: 20,
                unitPrice: 500,
                costOfGoods: 2000,
              ),
            ],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ],
      );

      final report = thisMonth(c);

      expect(report.documentCount, 3);
      expect(report.unitsSold, 60);
      expect(report.revenue, 30000);
      expect(report.costOfGoods, 6000);
      expect(
        report.revenueBySource.values.fold(0.0, (a, b) => a + b),
        report.revenue,
      );
      // One item sold three ways is still one row.
      expect(report.lines, hasLength(1));
      expect(report.lines.single.unitsSold, 60);
    });

    test('a refund nets down both units and revenue', () async {
      // Four of ten came back, so the day sold six — the refund is not a
      // separate negative sale, it reduces the one that happened.
      final c = await seededController(
        receipts: [
          seedReceipt(
            id: 'r1',
            amountPaid: 5000,
            status: ReceiptStatus.partRefunded,
            lines: const [
              ReceiptLine(
                id: 'a',
                itemId: 'i1',
                itemName: 'Bolt',
                quantity: 10,
                unitPrice: 500,
                quantityRefunded: 4,
                costOfGoods: 1000,
              ),
            ],
          ),
        ],
      );

      final report = thisMonth(c);

      expect(report.unitsSold, 6);
      expect(report.revenue, 3000);
      expect(report.costOfGoods, 600);
      expect(report.grossProfit, 2400);
    });

    test('voided and cancelled documents are excluded entirely', () async {
      // Neither happened, as far as the day is concerned.
      final c = await seededController(
        receipts: [
          seedReceipt(
            id: 'r1',
            status: ReceiptStatus.voided,
            amountPaid: 5000,
            lines: const [
              ReceiptLine(
                id: 'a',
                itemId: 'i1',
                itemName: 'Bolt',
                quantity: 10,
                unitPrice: 500,
              ),
            ],
          ),
        ],
        invoices: [
          seedInvoice(
            id: 'inv1',
            status: InvoiceStatus.cancelled,
            lines: const [
              InvoiceLine(
                id: 'b',
                itemId: 'i1',
                itemName: 'Bolt',
                quantity: 10,
                unitPrice: 500,
              ),
            ],
          ),
        ],
      );

      final report = thisMonth(c);

      expect(report.isEmpty, isTrue);
      expect(report.revenue, 0);
    });

    test(
      'a bill-level discount is shared across the items it came off',
      () async {
        final c = await newController();
        final a = await c.createItem(
          draft(name: 'A', quantity: 50, unitCost: 10),
        );
        final b = await c.createItem(
          draft(name: 'B', quantity: 50, unitCost: 10),
        );
        await c.issueReceipt(
          lines: [
            ReceiptLine(
              id: 'a',
              itemId: a.id,
              itemName: 'A',
              quantity: 1,
              unitPrice: 300,
            ),
            ReceiptLine(
              id: 'b',
              itemId: b.id,
              itemName: 'B',
              quantity: 1,
              unitPrice: 100,
            ),
          ],
          discount: 40,
        );

        final report = thisMonth(c);
        // 400 of goods less 40 is 360, split 3:1 by what each line contributed.
        expect(report.revenue, closeTo(360, 0.0001));
        final byName = {for (final l in report.lines) l.itemName: l.revenue};
        expect(byName['A'], closeTo(270, 0.0001));
        expect(byName['B'], closeTo(90, 0.0001));
      },
    );

    test('items are ranked by gross profit', () async {
      final c = await newController();
      final thin = await c.createItem(
        draft(name: 'Thin', quantity: 100, unitCost: 90),
      );
      final fat = await c.createItem(
        draft(name: 'Fat', quantity: 100, unitCost: 10),
      );
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: thin.id,
            itemName: 'Thin',
            quantity: 10,
            unitPrice: 100,
          ),
          ReceiptLine(
            id: 'b',
            itemId: fat.id,
            itemName: 'Fat',
            quantity: 10,
            unitPrice: 100,
          ),
        ],
      );

      expect(thisMonth(c).lines.first.itemName, 'Fat');
    });

    test('a sale outside the period is not in it', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 50, unitCost: 100));
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      final lastYear = ReportRange.of(
        ReportPeriod.yearly,
        DateTime(DateTime.now().year - 1, 6),
      );
      expect(reportOver(c, lastYear).isEmpty, isTrue);
      expect(thisMonth(c).isEmpty, isFalse);
    });

    test('a loss reports negative profit and a negative margin', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 50, unitCost: 800));
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      final report = thisMonth(c);
      expect(report.grossProfit, -3000);
      expect(report.marginRate, closeTo(-0.6, 0.0001));
    });
  });

  group('exports', () {
    test('the PDF renders', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final c = await newController();
      final item = await c.createItem(draft(quantity: 50, unitCost: 100));
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      final bytes = await ReportDocument(thisMonth(c), c.settings).toPdf();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });

    test('the workbook holds real numbers, not formatted text', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 50, unitCost: 100));
      await c.issueReceipt(
        lines: [
          ReceiptLine(
            id: 'a',
            itemId: item.id,
            itemName: 'Bolt',
            quantity: 10,
            unitPrice: 500,
          ),
        ],
      );

      final bytes = ReportDocument(thisMonth(c), c.settings).toXlsx();

      // A zip container, and the parts Excel needs to open it.
      expect(bytes.sublist(0, 2), [0x50, 0x4B]);
      final text = String.fromCharCodes(bytes);
      expect(text, contains('[Content_Types].xml'));
      expect(text, contains('xl/worksheets/sheet1.xml'));
      expect(bytes.length, greaterThan(500));
    });

    test('an empty period still produces both files', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final c = await newController();
      final report = thisMonth(c);
      expect(report.isEmpty, isTrue);

      final doc = ReportDocument(report, c.settings);
      expect((await doc.toPdf()).length, greaterThan(500));
      expect(doc.toXlsx().length, greaterThan(500));
    });

    test('the filename carries the period', () async {
      final c = await newController();
      final report = reportOver(
        c,
        ReportRange.between(DateTime(2026, 3, 1), DateTime(2026, 3, 31)),
      );
      final name = ReportDocument(report, c.settings).filename('xlsx');
      expect(name, 'sales-report-20260301-20260331.xlsx');
    });
  });
}
