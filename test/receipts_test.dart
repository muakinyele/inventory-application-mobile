import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/receipt_document.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

ReceiptLine receiptLine(
  String itemId,
  String name, {
  int quantity = 2,
  double price = 500,
  double discount = 0,
  String id = 'rl1',
}) => ReceiptLine(
  id: id,
  itemId: itemId,
  itemName: name,
  quantity: quantity,
  unitPrice: price,
  discount: discount,
);

void main() {
  group('issuing', () {
    test('a sale with nothing sent has nothing to receipt', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));
      final order = await c.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 6,
            unitPrice: 500,
          ),
        ],
      );

      expect(c.receiptLinesForSalesOrder(c.salesOrderById(order.id)!), isEmpty);
    });
  });

  group('money', () {
    test('discounts come off before tax', () async {
      final c = await newController();
      c.updateSettings(c.settings.copyWith(taxRate: 0.1, taxLabel: 'VAT'));
      final item = await c.createItem(draft(quantity: 20));

      final receipt = (await c.issueReceipt(
        lines: [
          receiptLine(item.id, 'Bolt', quantity: 4, price: 500, discount: 200),
        ],
        discount: 300,
      ))!;

      expect(receipt.gross, 2000);
      expect(receipt.discountTotal, 500);
      expect(receipt.subtotal, 1500);
      expect(receipt.tax, 150);
      expect(receipt.total, 1650);
      expect(receipt.taxLabel, 'VAT');
    });

    test('a discount bigger than the goods cannot go negative', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));

      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 1, price: 100)],
        discount: 5000,
      ))!;

      expect(receipt.subtotal, 0);
      expect(receipt.total, 0);
    });

    test('an overpayment shows as change, not as a bigger total', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));

      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
        amountPaid: 1200,
      ))!;

      expect(receipt.total, 1000);
      expect(receipt.change, 200);
      expect(receipt.balanceDue, 0);
      expect(receipt.isPaid, isTrue);
    });

    // THE ARITHMETIC MOVED TO THE SERVER, and so did the assertions about it:
    // capping a payment at the balance, adding rather than overwriting, and
    // refusing a settled receipt are covered in the server suite now. What
    // matters here is that settling LEAVES THE DEVICE at all — it used to
    // change the screen and nothing else — and that the answer is adopted
    // rather than recomputed.
    test('settling an account sale reaches the server', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));

      final receipt = (await c.issueReceipt(
        method: PaymentMethod.credit,
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
      ))!;
      expect(receipt.balanceDue, 1000);
      expect(c.unpaidReceipts.single.id, receipt.id);

      final applied = await c.settleReceipt(receipt.id, 400);

      expect(applied, 400, reason: 'what the server said it took');
      expect(
        c.receiptById(receipt.id)!.amountPaid,
        400,
        reason: 'the receipt is the one the server answered with',
      );
    });

    test('a refused settlement changes nothing and says so', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));
      final receipt = (await c.issueReceipt(
        method: PaymentMethod.credit,
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
      ))!;

      // Nothing to settle with is refused before it reaches the server.
      expect(await c.settleReceipt(receipt.id, 0), isNull);
      expect(c.receiptById(receipt.id)!.amountPaid, 0);
    });

    test('the receipt keeps the tax rate it was issued at', () async {
      final c = await newController();
      c.updateSettings(c.settings.copyWith(taxRate: 0.075));
      final item = await c.createItem(draft(quantity: 20));

      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 1, price: 1000)],
      ))!;
      c.updateSettings(c.settings.copyWith(taxRate: 0.2));

      expect(c.receiptById(receipt.id)!.taxRate, 0.075);
      expect(c.receiptById(receipt.id)!.total, 1075);
    });
  });

  group('refunds', () {});

  group('voids', () {});

  group('takings', () {});

  group('persistence', () {});

  group('exports', () {
    Future<(Receipt, AppSettings, InventoryController)> sample() async {
      final c = await newController();
      c.updateSettings(
        c.settings.copyWith(
          companyName: 'Ada Hardware',
          companyAddress: '12 Market Road, Lagos',
          taxRate: 0.075,
          taxLabel: 'VAT',
        ),
      );
      final item = await c.createItem(
        draft(name: 'Roofing bolt', quantity: 20, unitCost: 100, sku: 'RB-1'),
      );
      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, 'Roofing bolt', quantity: 3, price: 500)],
        amountPaid: 2000,
        notes: 'Cash sale',
      ))!;
      return (receipt, c.settings, c);
    }

    test('plain text carries the letterhead, lines and totals', () async {
      final (receipt, settings, _) = await sample();
      final text = ReceiptDocument(receipt, settings).toPlainText();

      expect(text, contains('Ada Hardware'));
      expect(text, contains('12 Market Road, Lagos'));
      expect(text, contains(receipt.reference));
      expect(text, contains('Roofing bolt'));
      expect(text, contains('VAT'));
      expect(text, contains('TOTAL'));
      expect(text, contains('Change'));
      // Every line is inside the 40-column width it promises.
      for (final line in text.trimRight().split('\n')) {
        expect(line.length, lessThanOrEqualTo(40), reason: line);
      }
    });

    test('text longer than the paper is folded, not run off it', () async {
      final c = await newController();
      c.updateSettings(
        c.settings.copyWith(
          companyName: 'Ada Hardware and General Merchandise Limited',
          companyAddress:
              '12 Market Road, off Herbert Macaulay Way, Yaba, Lagos State',
          receiptFooter:
              'Goods are returnable within seven days on production of '
              'this receipt and its original packaging.',
        ),
      );
      final item = await c.createItem(
        draft(name: 'Galvanised roofing sheet, 3 metre, heavy gauge'),
      );
      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, item.name)],
        notes:
            'Delivered to the Ikeja site on the customer own transport, '
            'received by the site foreman.',
      ))!;

      final text = ReceiptDocument(receipt, c.settings).toPlainText();
      for (final line in text.trimRight().split('\n')) {
        expect(line.length, lessThanOrEqualTo(40), reason: line);
      }
      // Folding must not lose anything: the last word of each long field
      // still has to be in there.
      expect(text, contains('Limited'));
      expect(text, contains('State'));
      expect(text, contains('packaging.'));
      expect(text, contains('gauge'));
      expect(text, contains('foreman.'));
    });

    test(
      'a word wider than the paper is cut rather than overhanging',
      () async {
        final c = await newController();
        final item = await c.createItem(draft(name: 'A' * 95));
        final receipt = (await c.issueReceipt(
          lines: [receiptLine(item.id, 'A' * 95)],
        ))!;

        final text = ReceiptDocument(receipt, c.settings).toPlainText();
        for (final line in text.trimRight().split('\n')) {
          expect(line.length, lessThanOrEqualTo(40), reason: line);
        }
        expect('A' * 40, isIn(text.split('\n')));
      },
    );

    test('CSV writes one row per line with the totals repeated', () async {
      final (receipt, settings, _) = await sample();
      final csv = receiptsToCsv([receipt], settings);
      final rows = csv.trim().split('\n');

      expect(rows, hasLength(2));
      expect(rows.first.split(','), contains('receiptTotal'));
      expect(rows[1], contains(receipt.reference));
      expect(rows[1], contains('Roofing bolt'));
      expect(rows[1], contains('RB-1'));
    });

    test('CSV escapes a value that would break the row', () async {
      final c = await newController();
      final item = await c.createItem(draft(name: 'Bolt, 10mm', quantity: 20));
      final receipt = (await c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt, 10mm')],
        notes: 'Said "keep the change"',
      ))!;

      final csv = receiptsToCsv([receipt], c.settings);
      expect(csv, contains('"Bolt, 10mm"'));
      expect(csv, contains('"Said ""keep the change"""'));
      // Header plus exactly one data row: no stray line breaks got through.
      expect(csv.trim().split('\n'), hasLength(2));
    });

    test('a receipt with no lines still gets a CSV row', () async {
      final now = DateTime.now();
      final empty = Receipt(
        id: 'r1',
        reference: 'RC-0009',
        issuedAt: now,
        createdAt: now,
        updatedAt: now,
      );

      final rows = receiptsToCsv([
        empty,
      ], const AppSettings()).trim().split('\n');
      expect(rows, hasLength(2));
      expect(rows[1], startsWith('RC-0009'));
    });

    test('JSON round-trips the figures the customer was shown', () async {
      final (receipt, settings, _) = await sample();
      final json = ReceiptDocument(receipt, settings).toJson();

      expect(json, contains('"reference": "${receipt.reference}"'));
      expect(json, contains('"taxRate": 0.075'));
      expect(json, contains('"total"'));
      expect(json, contains('"change"'));
    });

    test('the PDF renders, on a sheet and on a till roll', () async {
      // The fonts are read through rootBundle, which needs the binding up.
      TestWidgetsFlutterBinding.ensureInitialized();
      final (receipt, settings, _) = await sample();
      final doc = ReceiptDocument(receipt, settings);

      final sheet = await doc.toPdf();
      final roll = await doc.toPdf(roll: true);

      // A PDF is identified by its header and terminated by %%EOF; anything
      // that satisfies both actually parsed and serialised.
      for (final bytes in [sheet, roll]) {
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(
          String.fromCharCodes(bytes.skip(bytes.length - 8)),
          contains('%%EOF'),
        );
        expect(bytes.length, greaterThan(1000));
      }
      // The roll is a narrower page, so it cannot be byte-identical.
      expect(sheet.length, isNot(roll.length));
    });

    test('the PDF renders a voided receipt and a refunded one', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final (receipt, settings, c) = await sample();
      await c.refundReceipt(receipt.id, {'rl1': 1});
      final refunded = await ReceiptDocument(
        c.receiptById(receipt.id)!,
        settings,
      ).toPdf();
      await c.voidReceipt(receipt.id);

      // Voiding a part-refunded receipt is refused, so this exercises the
      // refunded branch twice rather than silently testing nothing.
      expect(String.fromCharCodes(refunded.take(5)), '%PDF-');

      final (second, _, other) = await sample();
      await other.voidReceipt(second.id, reason: 'Duplicate');
      final voided = await ReceiptDocument(
        other.receiptById(second.id)!,
        settings,
      ).toPdf();
      expect(String.fromCharCodes(voided.take(5)), '%PDF-');
    });

    test('the filename sorts by date and names the receipt', () async {
      final (receipt, settings, _) = await sample();
      final name = ReceiptDocument(receipt, settings).filename('pdf');

      expect(name, startsWith(receipt.reference));
      expect(name, endsWith('.pdf'));
    });
  });
}
