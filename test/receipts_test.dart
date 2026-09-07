import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/receipt_document.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/movement.dart';
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
    test('a counter sale takes the stock off the shelf', () async {
      final c = await newController();
      final item = c.createItem(draft(name: 'Bolt', quantity: 20, unitCost: 100));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 3, price: 500)],
        amountPaid: 1500,
      );

      expect(receipt, isNotNull);
      expect(c.byId(item.id)!.quantity, 17);
      expect(receipt!.total, 1500);
      expect(receipt.isPaid, isTrue);
      expect(receipt.change, 0);
      expect(receipt.movesStock, isTrue);
    });

    test('references run in their own sequence and are never reused', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 50));

      final first = c.issueReceipt(lines: [receiptLine(item.id, 'Bolt')])!;
      final second = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', id: 'rl2')],
      )!;
      c.deleteReceipt(second.id);
      final third = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', id: 'rl3')],
      )!;

      expect(first.reference, 'RC-0001');
      expect(second.reference, 'RC-0002');
      expect(third.reference, 'RC-0003');
    });

    test('the ledger records the sale against the receipt', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4)],
      )!;

      final movement = c.movements.first;
      expect(movement.kind, MovementKind.stockOut);
      expect(movement.documentId, receipt.id);
      expect(movement.before, 20);
      expect(movement.after, 16);
      expect(movement.note, contains(receipt.reference));
    });

    test('a line is trimmed to what is actually on the shelf', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 5));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 9, price: 100)],
      )!;

      expect(receipt.lines.single.quantity, 5);
      expect(receipt.total, 500);
      expect(c.byId(item.id)!.quantity, 0);
    });

    test('two lines for one item draw down the same stock', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 5));

      final receipt = c.issueReceipt(
        lines: [
          receiptLine(item.id, 'Bolt', quantity: 3, id: 'a'),
          receiptLine(item.id, 'Bolt', quantity: 4, id: 'b'),
        ],
      )!;

      // The second line only gets what the first left behind.
      expect(receipt.lines.map((l) => l.quantity), [3, 2]);
      expect(c.byId(item.id)!.quantity, 0);
    });

    test('nothing on the shelf means no receipt at all', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 0));

      expect(c.issueReceipt(lines: [receiptLine(item.id, 'Bolt')]), isNull);
      expect(c.receipts, isEmpty);
    });

    test('cost of goods is banked at the average when it leaves', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 10, unitCost: 120));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 3, price: 500)],
      )!;
      // A later cost change must not rewrite what the sale actually cost.
      c.updateItem(item.id, c.byId(item.id)!.copyWith(unitCost: 900));

      expect(c.receiptById(receipt.id)!.costOfGoods, 360);
      expect(c.receiptById(receipt.id)!.grossProfit, 1140);
    });

    test('a receipt against a sale moves no stock', () async {
      final c = await newController();
      final item = c.createItem(draft(name: 'Bolt', quantity: 20));
      final order = c.createSalesOrder(
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
      c.confirmSalesOrder(order.id);
      c.fulfilSalesOrder(order.id, {'l1': 6});
      expect(c.byId(item.id)!.quantity, 14);

      final lines = c.receiptLinesForSalesOrder(c.salesOrderById(order.id)!);
      final receipt = c.issueReceipt(
        salesOrderId: order.id,
        lines: lines,
        amountPaid: 3000,
      )!;

      // The despatch already took the stock; the receipt must not take it twice.
      expect(c.byId(item.id)!.quantity, 14);
      expect(receipt.movesStock, isFalse);
      expect(receipt.total, 3000);
      expect(c.receiptsForSalesOrder(order.id).single.id, receipt.id);
    });

    test('a sale with nothing sent has nothing to receipt', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final order = c.createSalesOrder(
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
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        lines: [
          receiptLine(item.id, 'Bolt', quantity: 4, price: 500, discount: 200),
        ],
        discount: 300,
      )!;

      expect(receipt.gross, 2000);
      expect(receipt.discountTotal, 500);
      expect(receipt.subtotal, 1500);
      expect(receipt.tax, 150);
      expect(receipt.total, 1650);
      expect(receipt.taxLabel, 'VAT');
    });

    test('a discount bigger than the goods cannot go negative', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 1, price: 100)],
        discount: 5000,
      )!;

      expect(receipt.subtotal, 0);
      expect(receipt.total, 0);
    });

    test('an overpayment shows as change, not as a bigger total', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
        amountPaid: 1200,
      )!;

      expect(receipt.total, 1000);
      expect(receipt.change, 200);
      expect(receipt.balanceDue, 0);
      expect(receipt.isPaid, isTrue);
    });

    test('an account sale is left owing and can be settled', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        method: PaymentMethod.credit,
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
      )!;
      expect(receipt.balanceDue, 1000);
      expect(c.unpaidReceipts.single.id, receipt.id);

      c.settleReceipt(receipt.id, 400);
      expect(c.receiptById(receipt.id)!.balanceDue, 600);

      // Paying more than is owed never turns into change that was never given.
      c.settleReceipt(receipt.id, 5000, method: PaymentMethod.cash);
      final settled = c.receiptById(receipt.id)!;
      expect(settled.amountPaid, 1000);
      expect(settled.isPaid, isTrue);
      expect(settled.change, 0);
      expect(c.unpaidReceipts, isEmpty);
    });

    test('the receipt keeps the tax rate it was issued at', () async {
      final c = await newController();
      c.updateSettings(c.settings.copyWith(taxRate: 0.075));
      final item = c.createItem(draft(quantity: 20));

      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 1, price: 1000)],
      )!;
      c.updateSettings(c.settings.copyWith(taxRate: 0.2));

      expect(c.receiptById(receipt.id)!.taxRate, 0.075);
      expect(c.receiptById(receipt.id)!.total, 1075);
    });
  });

  group('refunds', () {
    test('goods coming back go on the shelf and net the receipt down', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20, unitCost: 100));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4, price: 500)],
        amountPaid: 2000,
      )!;
      expect(c.byId(item.id)!.quantity, 16);

      final moved = c.refundReceipt(receipt.id, {'rl1': 1});

      expect(moved, 1);
      expect(c.byId(item.id)!.quantity, 17);
      final after = c.receiptById(receipt.id)!;
      expect(after.status, ReceiptStatus.partRefunded);
      expect(after.refundTotal, 500);
      expect(after.netTotal, 1500);
      expect(after.unitsKept, 3);
      expect(c.movements.first.kind, MovementKind.stockIn);
      expect(c.movements.first.documentId, receipt.id);
    });

    test('refunding everything closes the receipt', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;

      c.refundReceipt(receipt.id, {'rl1': 4});
      final after = c.receiptById(receipt.id)!;

      expect(after.status, ReceiptStatus.refunded);
      expect(after.netTotal, 0);
      expect(after.isFullyRefunded, isTrue);
      expect(c.byId(item.id)!.quantity, 20);
    });

    test('a refund gives back its share of discount and tax', () async {
      final c = await newController();
      c.updateSettings(c.settings.copyWith(taxRate: 0.1));
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4, price: 500)],
        discount: 400,
      )!;
      // 2000 - 400 = 1600 + 10% = 1760.
      expect(receipt.total, closeTo(1760, 0.001));

      c.refundReceipt(receipt.id, {'rl1': 2});
      final after = c.receiptById(receipt.id)!;

      // Half the goods back: half the discounted subtotal, plus its tax.
      expect(after.refundTotal, closeTo(880, 0.001));
      expect(after.netTotal, closeTo(880, 0.001));
    });

    test('a refund without restocking returns money but no stock', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;
      expect(c.byId(item.id)!.quantity, 16);

      c.refundReceipt(receipt.id, {'rl1': 2}, restock: false);

      expect(c.byId(item.id)!.quantity, 16);
      expect(c.receiptById(receipt.id)!.refundTotal, 1000);
    });

    test('a refund never exceeds what is left un-refunded', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 3, price: 500)],
      )!;

      c.refundReceipt(receipt.id, {'rl1': 99});
      expect(c.receiptById(receipt.id)!.unitsRefunded, 3);

      // Nothing left to give back.
      expect(c.refundReceipt(receipt.id, {'rl1': 1}), 0);
      expect(c.byId(item.id)!.quantity, 20);
    });
  });

  group('voids', () {
    test('a void puts back exactly what the receipt took', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [
          receiptLine(item.id, 'Bolt', quantity: 3, id: 'a'),
          receiptLine(item.id, 'Bolt', quantity: 2, id: 'b'),
        ],
      )!;
      expect(c.byId(item.id)!.quantity, 15);

      expect(c.voidReceipt(receipt.id, reason: 'Rang up twice'), isTrue);

      expect(c.byId(item.id)!.quantity, 20);
      final after = c.receiptById(receipt.id)!;
      expect(after.status, ReceiptStatus.voided);
      expect(after.voidReason, 'Rang up twice');
      expect(after.netTotal, 0);
      expect(after.costOfGoods, 0);
    });

    test('voiding a receipt against a sale moves no stock', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final order = c.createSalesOrder(
        lines: [
          SalesOrderLine(
            id: 'l1',
            itemId: item.id,
            itemName: 'Bolt',
            quantityOrdered: 5,
            unitPrice: 500,
          ),
        ],
      );
      c.confirmSalesOrder(order.id);
      c.fulfilSalesOrder(order.id, {'l1': 5});

      final receipt = c.issueReceipt(
        salesOrderId: order.id,
        lines: c.receiptLinesForSalesOrder(c.salesOrderById(order.id)!),
      )!;
      c.voidReceipt(receipt.id);

      // The goods are still with the customer — the sale sent them.
      expect(c.byId(item.id)!.quantity, 15);
    });

    test('a receipt with refunds against it cannot be voided', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 4)],
      )!;
      c.refundReceipt(receipt.id, {'rl1': 1});

      expect(c.voidReceipt(receipt.id), isFalse);
      expect(c.receiptById(receipt.id)!.status, ReceiptStatus.partRefunded);
    });

    test('only a voided receipt can be deleted', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt')],
      )!;

      c.deleteReceipt(receipt.id);
      expect(c.receipts, hasLength(1));

      c.voidReceipt(receipt.id);
      c.deleteReceipt(receipt.id);
      expect(c.receipts, isEmpty);
    });
  });

  group('takings', () {
    test('voids and refunds are netted out of the day', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 50));

      c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 2, price: 500)],
      );
      final refunded = c.issueReceipt(
        method: PaymentMethod.card,
        lines: [receiptLine(item.id, 'Bolt', quantity: 4, price: 500, id: 'b')],
      )!;
      final voided = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt', quantity: 6, price: 500, id: 'c')],
      )!;

      c.refundReceipt(refunded.id, {'b': 2});
      c.voidReceipt(voided.id);

      // 1000 cash + (2000 - 1000) card, and nothing from the void.
      expect(c.takings, 2000);
      expect(c.takingsOn(DateTime.now()), 2000);
      final byMethod = c.takingsByMethod(day: DateTime.now());
      expect(byMethod[PaymentMethod.cash], 1000);
      expect(byMethod[PaymentMethod.card], 1000);
    });
  });

  group('persistence', () {
    test('receipts survive a reload, refunds and all', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final item = c.createItem(draft(quantity: 20, unitCost: 100));
      final receipt = c.issueReceipt(
        method: PaymentMethod.transfer,
        lines: [
          receiptLine(item.id, 'Bolt', quantity: 4, price: 500, discount: 100),
        ],
        discount: 200,
        amountPaid: 1700,
        notes: 'Collected in person',
        cashier: 'Ada',
      )!;
      c.refundReceipt(receipt.id, {'rl1': 1});
      await pumpWrites();

      final reloaded = await controllerOver(repo);
      final stored = reloaded.receiptById(receipt.id)!;

      expect(stored.reference, receipt.reference);
      expect(stored.method, PaymentMethod.transfer);
      expect(stored.status, ReceiptStatus.partRefunded);
      expect(stored.discount, 200);
      expect(stored.amountPaid, 1700);
      expect(stored.notes, 'Collected in person');
      expect(stored.cashier, 'Ada');
      expect(stored.lines.single.discount, 100);
      expect(stored.lines.single.quantityRefunded, 1);
      expect(stored.lines.single.costOfGoods, 400);
      // 2000 less 100 off the line and 200 off the bill is 1700, and a
      // quarter of the goods went back, so three quarters of it survives.
      expect(stored.netTotal, closeTo(1275, 0.001));
      expect(stored.netTotal, closeTo(reloaded.takings, 0.001));
    });

    test('erasing everything clears the receipt book', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final item = c.createItem(draft(quantity: 20));
      c.issueReceipt(lines: [receiptLine(item.id, 'Bolt')]);
      await pumpWrites();

      c.eraseAll();
      await pumpWrites();

      expect((await controllerOver(repo)).receipts, isEmpty);
    });
  });

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
      final item = c.createItem(
        draft(name: 'Roofing bolt', quantity: 20, unitCost: 100, sku: 'RB-1'),
      );
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Roofing bolt', quantity: 3, price: 500)],
        amountPaid: 2000,
        notes: 'Cash sale',
      )!;
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
      final item = c.createItem(
        draft(name: 'Galvanised roofing sheet, 3 metre, heavy gauge'),
      );
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, item.name)],
        notes: 'Delivered to the Ikeja site on the customer own transport, '
            'received by the site foreman.',
      )!;

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

    test('a word wider than the paper is cut rather than overhanging', () async {
      final c = await newController();
      final item = c.createItem(draft(name: 'A' * 95));
      final receipt = c.issueReceipt(lines: [receiptLine(item.id, 'A' * 95)])!;

      final text = ReceiptDocument(receipt, c.settings).toPlainText();
      for (final line in text.trimRight().split('\n')) {
        expect(line.length, lessThanOrEqualTo(40), reason: line);
      }
      expect('A' * 40, isIn(text.split('\n')));
    });

    test('a voided receipt says so in plain text', () async {
      final (receipt, settings, c) = await sample();
      c.voidReceipt(receipt.id, reason: 'Duplicate');
      final text = ReceiptDocument(
        c.receiptById(receipt.id)!,
        settings,
      ).toPlainText();

      expect(text, contains('VOIDED'));
      expect(text, contains('Duplicate'));
    });

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
      final item = c.createItem(draft(name: 'Bolt, 10mm', quantity: 20));
      final receipt = c.issueReceipt(
        lines: [receiptLine(item.id, 'Bolt, 10mm')],
        notes: 'Said "keep the change"',
      )!;

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

      final rows = receiptsToCsv([empty], const AppSettings()).trim().split('\n');
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
      c.refundReceipt(receipt.id, {'rl1': 1});
      final refunded = await ReceiptDocument(
        c.receiptById(receipt.id)!,
        settings,
      ).toPdf();
      c.voidReceipt(receipt.id);

      // Voiding a part-refunded receipt is refused, so this exercises the
      // refunded branch twice rather than silently testing nothing.
      expect(String.fromCharCodes(refunded.take(5)), '%PDF-');

      final (second, _, other) = await sample();
      other.voidReceipt(second.id, reason: 'Duplicate');
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
