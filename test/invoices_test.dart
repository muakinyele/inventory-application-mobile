import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/invoice.dart';

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
  group('issuing', () {});

  group('payment', () {});

  group('overdue', () {
    test('an invoice past its due date with money owing is overdue', () async {
      final c = await newController();
      final item = await c.createItem(draft(quantity: 20));
      final invoice = (await c.issueInvoice(
        lines: [invoiceLine(item.id, 'Bolt')],
        dueAt: DateTime.now().subtract(const Duration(days: 3)),
      ))!;

      expect(c.invoiceById(invoice.id)!.isOverdue, isTrue);
      expect(c.invoiceById(invoice.id)!.daysOverdue, greaterThanOrEqualTo(2));
      expect(c.overdueInvoices, hasLength(1));
    });
  });

  group('cancellation', () {});

  group('persistence', () {});
}
