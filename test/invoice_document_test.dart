import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/invoice_document.dart';
import 'package:stockpile/models/invoice.dart';

import 'support.dart';

InvoiceLine line(
  String itemId, {
  int quantity = 4,
  double price = 500,
  String id = 'il1',
  String name = 'Bolt',
}) => InvoiceLine(
  id: id,
  itemId: itemId,
  itemName: name,
  sku: 'B-1',
  quantity: quantity,
  unitPrice: price,
);

void main() {
  test('the PDF renders unpaid, part paid and cancelled', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = await newController();
    c.updateSettings(
      c.settings.copyWith(
        companyName: 'Ada Hardware',
        companyAddress: '12 Market Road, Lagos',
        taxRate: 0.075,
      ),
    );
    final item = await c.createItem(
      draft(name: 'Bolt', quantity: 50, unitCost: 100, sku: 'B-1'),
    );

    final unpaid = (await c.issueInvoice(
      lines: [line(item.id)],
      termDays: 30,
      terms: '30 days net',
    ))!;
    var bytes = await InvoiceDocument(unpaid, c.settings).toPdf();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));

    // A part-paid invoice lists each receipt against the balance, so the
    // payments path has to render too.
    c.payInvoice(unpaid.id, 500);
    final partPaid = c.invoiceById(unpaid.id)!;
    bytes = await InvoiceDocument(
      partPaid,
      c.settings,
      payments: c.paymentsForInvoice(partPaid.id),
    ).toPdf();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    final other = (await c.issueInvoice(lines: [line(item.id, id: 'x')]))!;
    c.cancelInvoice(other.id, reason: 'Duplicate');
    bytes = await InvoiceDocument(c.invoiceById(other.id)!, c.settings).toPdf();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('an overdue invoice renders', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = await newController();
    final item = await c.createItem(draft(quantity: 50));
    final invoice = (await c.issueInvoice(
      lines: [line(item.id)],
      dueAt: DateTime.now().subtract(const Duration(days: 10)),
    ))!;

    expect(invoice.isOverdue, isTrue);
    final bytes = await InvoiceDocument(invoice, c.settings).toPdf();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test(
    'the CSV carries the balance and escapes what would break a row',
    () async {
      final c = await newController();
      final item = await c.createItem(draft(name: 'Bolt, 10mm', quantity: 50));
      final invoice = (await c.issueInvoice(
        lines: [line(item.id, name: 'Bolt, 10mm')],
        notes: 'Said "invoice it"',
      ))!;
      c.payInvoice(invoice.id, 500);

      final csv = invoicesToCsv([c.invoiceById(invoice.id)!]);
      final rows = csv.trim().split('\n');

      expect(rows, hasLength(2));
      expect(rows.first.split(','), contains('balanceDue'));
      expect(csv, contains('"Bolt, 10mm"'));
      // A quote inside a quoted cell is doubled, per RFC 4180.
      expect(csv, contains('"Said ""invoice it"""'));
      // 2000 billed less 500 paid.
      expect(rows[1], contains('1500'));
    },
  );

  test('the filename names the invoice', () async {
    final c = await newController();
    final item = await c.createItem(draft(quantity: 50));
    final invoice = (await c.issueInvoice(lines: [line(item.id)]))!;

    final name = InvoiceDocument(invoice, c.settings).filename('pdf');
    expect(name, startsWith(invoice.reference));
    expect(name, endsWith('.pdf'));
  });
}
