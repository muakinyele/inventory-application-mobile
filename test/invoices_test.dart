import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/invoice.dart';
import 'package:stockpile/models/movement.dart';
import 'package:stockpile/models/receipt.dart';
import 'package:stockpile/models/sales_order.dart';

import 'support.dart';

InvoiceLine invoiceLine(
  String itemId,
  String name, {
  int quantity = 4,
  double price = 500,
  double discount = 0,
  String id = 'il1',
}) => InvoiceLine(
  id: id,
  itemId: itemId,
  itemName: name,
  quantity: quantity,
  unitPrice: price,
  discount: discount,
);

void main() {
  group('issuing', () {
    test('a credit sale takes stock and books the money as owed', () async {
      final c = await newController();
      final item = c.createItem(
        draft(name: 'Bolt', quantity: 20, unitCost: 100),
      );

      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
        termDays: 30,
      );

      expect(invoice, isNotNull);
      expect(c.byId(item.id)!.quantity, 16);
      expect(invoice!.total, 2000);
      expect(invoice.amountPaid, 0);
      expect(invoice.balanceDue, 2000);
      expect(invoice.status, InvoiceStatus.open);
      expect(invoice.movesStock, isTrue);
      expect(invoice.dueAt, isNotNull);
      expect(c.totalReceivable, 2000);
    });

    test('references run in their own sequence', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 50));

      final first = c.issueInvoice(lines: [invoiceLine(item.id, 'Bolt')])!;
      final second = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', id: 'il2')],
      )!;

      expect(first.reference, 'INV-0001');
      expect(second.reference, 'INV-0002');
    });

    test('the ledger records the sale against the invoice', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));

      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 5)],
      )!;

      final movement = c.movements.first;
      expect(movement.kind, MovementKind.stockOut);
      expect(movement.documentId, invoice.id);
      expect(movement.note, contains(invoice.reference));
      expect(movement.before, 20);
      expect(movement.after, 15);
    });

    test('a line is trimmed to what is on the shelf', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 3));

      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 9, price: 100)],
      )!;

      expect(invoice.lines.single.quantity, 3);
      expect(c.byId(item.id)!.quantity, 0);
    });

    test('an invoice against a sale moves no stock', () async {
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
      c.confirmSalesOrder(order.id);
      c.fulfilSalesOrder(order.id, {'l1': 6});
      expect(c.byId(item.id)!.quantity, 14);

      final invoice = c.issueInvoice(
        salesOrderId: order.id,
        lines: c.invoiceLinesForSalesOrder(c.salesOrderById(order.id)!),
      )!;

      expect(c.byId(item.id)!.quantity, 14);
      expect(invoice.movesStock, isFalse);
      expect(c.invoicesForSalesOrder(order.id).single.id, invoice.id);
    });
  });

  group('payment', () {
    test('paying issues a receipt and brings the balance down', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20, unitCost: 100));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;

      final receipt = c.payInvoice(
        invoice.id,
        800,
        method: PaymentMethod.transfer,
      );

      expect(receipt, isNotNull);
      expect(receipt!.invoiceId, invoice.id);
      expect(receipt.amountPaid, 800);
      expect(receipt.method, PaymentMethod.transfer);
      // The goods already left when the invoice was raised.
      expect(receipt.movesStock, isFalse);
      expect(c.byId(item.id)!.quantity, 16);

      final after = c.invoiceById(invoice.id)!;
      expect(after.amountPaid, 800);
      expect(after.balanceDue, 1200);
      expect(after.status, InvoiceStatus.partPaid);
      expect(
        c.paymentsForInvoice(invoice.id).single.reference,
        receipt.reference,
      );
    });

    test('paying it off in full closes the invoice', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;

      c.payInvoice(invoice.id, 1200);
      c.payInvoice(invoice.id, 800);

      final after = c.invoiceById(invoice.id)!;
      expect(after.status, InvoiceStatus.paid);
      expect(after.isSettled, isTrue);
      expect(after.balanceDue, 0);
      expect(after.closedAt, isNotNull);
      expect(c.paymentsForInvoice(invoice.id), hasLength(2));
      expect(c.totalReceivable, 0);
    });

    test('a payment never exceeds the balance', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;

      final receipt = c.payInvoice(invoice.id, 999999)!;

      expect(receipt.amountPaid, 2000);
      expect(c.invoiceById(invoice.id)!.balanceDue, 0);
      // A receipt that took only what was owed gives no change.
      expect(receipt.change, 0);
    });

    test('a settled invoice takes no further payment', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;
      c.payInvoice(invoice.id, 2000);

      expect(c.payInvoice(invoice.id, 500), isNull);
      expect(c.receipts, hasLength(1));
    });

    test('takings count the money paid, not the invoice value', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;

      c.payInvoice(invoice.id, 750, method: PaymentMethod.cash);

      // The receipt reprints the whole 2000 invoice, but only 750 arrived.
      expect(c.takings, 750);
      expect(c.takingsByMethod()[PaymentMethod.cash], 750);
      // What is still owed lives on the invoice, not in unpaid receipts.
      expect(c.unpaidReceipts, isEmpty);
      expect(c.totalReceivable, 1250);
    });
  });

  group('overdue', () {
    test('an invoice past its due date with money owing is overdue', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt')],
        dueAt: DateTime.now().subtract(const Duration(days: 3)),
      )!;

      expect(c.invoiceById(invoice.id)!.isOverdue, isTrue);
      expect(c.invoiceById(invoice.id)!.daysOverdue, greaterThanOrEqualTo(2));
      expect(c.overdueInvoices, hasLength(1));
    });

    test('paying it clears the overdue flag', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
        dueAt: DateTime.now().subtract(const Duration(days: 3)),
      )!;

      c.payInvoice(invoice.id, 2000);

      expect(c.invoiceById(invoice.id)!.isOverdue, isFalse);
      expect(c.overdueInvoices, isEmpty);
    });
  });

  group('cancellation', () {
    test('cancelling puts back exactly what the invoice took', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [
          invoiceLine(item.id, 'Bolt', quantity: 3, id: 'a'),
          invoiceLine(item.id, 'Bolt', quantity: 2, id: 'b'),
        ],
      )!;
      expect(c.byId(item.id)!.quantity, 15);

      expect(c.cancelInvoice(invoice.id, reason: 'Duplicate'), isTrue);

      expect(c.byId(item.id)!.quantity, 20);
      final after = c.invoiceById(invoice.id)!;
      expect(after.status, InvoiceStatus.cancelled);
      expect(after.revenue, 0);
      expect(after.costOfGoods, 0);
      expect(after.outstanding, 0);
      expect(c.totalReceivable, 0);
    });

    test('an invoice with a payment against it cannot be cancelled', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt', quantity: 4, price: 500)],
      )!;
      c.payInvoice(invoice.id, 100);

      expect(c.cancelInvoice(invoice.id), isFalse);
      expect(c.invoiceById(invoice.id)!.status, InvoiceStatus.partPaid);
    });

    test('only a cancelled invoice can be deleted', () async {
      final c = await newController();
      final item = c.createItem(draft(quantity: 20));
      final invoice = c.issueInvoice(lines: [invoiceLine(item.id, 'Bolt')])!;

      c.deleteInvoice(invoice.id);
      expect(c.invoices, hasLength(1));

      c.cancelInvoice(invoice.id);
      c.deleteInvoice(invoice.id);
      expect(c.invoices, isEmpty);
    });
  });

  group('persistence', () {
    test('invoices and their payments survive a reload', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final item = c.createItem(draft(quantity: 20, unitCost: 100));
      final invoice = c.issueInvoice(
        lines: [
          invoiceLine(item.id, 'Bolt', quantity: 4, price: 500, discount: 100),
        ],
        discount: 200,
        termDays: 14,
        terms: '14 days net',
        notes: 'Delivered to site',
      )!;
      c.payInvoice(invoice.id, 500, method: PaymentMethod.transfer);
      await pumpWrites();

      final reloaded = await controllerOver(repo);
      final stored = reloaded.invoiceById(invoice.id)!;

      expect(stored.reference, invoice.reference);
      expect(stored.status, InvoiceStatus.partPaid);
      expect(stored.discount, 200);
      expect(stored.terms, '14 days net');
      expect(stored.notes, 'Delivered to site');
      expect(stored.dueAt, isNotNull);
      expect(stored.amountPaid, 500);
      expect(stored.lines.single.discount, 100);
      expect(stored.lines.single.costOfGoods, 400);
      expect(reloaded.paymentsForInvoice(invoice.id), hasLength(1));
      // The receipt kept its link back, which is what stops the payment being
      // read as a fresh sale on the next load.
      expect(reloaded.receipts.single.invoiceId, invoice.id);
    });

    test('erasing everything clears the invoice book', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final item = c.createItem(draft(quantity: 20));
      c.issueInvoice(lines: [invoiceLine(item.id, 'Bolt')]);
      await pumpWrites();

      c.eraseAll();
      await pumpWrites();

      expect((await controllerOver(repo)).invoices, isEmpty);
    });
  });
}
