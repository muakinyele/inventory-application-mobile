import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/csv_codec.dart';
import 'package:stockpile/data/receipt_document.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/receipt.dart';

const _settings = AppSettings(companyName: 'Chedra Olympas', currency: 'NGN');

Receipt _receipt({
  String reference = 'RC-0001',
  List<ReceiptLine> lines = const [
    ReceiptLine(
      id: 'l1',
      itemId: 'i1',
      itemName: 'Bolt',
      sku: 'B1',
      unit: 'pcs',
      quantity: 3,
      unitPrice: 500,
    ),
  ],
}) => Receipt(
  id: 'r-$reference',
  reference: reference,
  status: ReceiptStatus.issued,
  method: PaymentMethod.transfer,
  customerName: 'Ada Nwosu',
  lines: lines,
  taxRate: 0.075,
  taxLabel: 'VAT',
  amountPaid: 1000,
  notes: 'Counter sale',
  issuedAt: DateTime.utc(2026, 9, 3, 14, 30),
  createdAt: DateTime.utc(2026, 9, 3),
  updatedAt: DateTime.utc(2026, 9, 3),
);

void main() {
  group('receipts survive a trip through CSV', () {
    test('a single receipt comes back with its header fields', () {
      final csv = receiptsToCsv([_receipt()], _settings);

      final result = csvToReceipts(csv);

      expect(result.errors, isEmpty);
      final back = result.receipts.single;
      expect(back.reference, 'RC-0001');
      expect(back.customerName, 'Ada Nwosu');
      expect(back.method, PaymentMethod.transfer);
      expect(back.taxLabel, 'VAT');
      expect(back.taxRate, 0.075);
      expect(back.amountPaid, 1000);
      expect(back.notes, 'Counter sale');
      expect(back.issuedAt.toUtc(), DateTime.utc(2026, 9, 3, 14, 30));
    });

    test('the lines come back', () {
      final csv = receiptsToCsv([_receipt()], _settings);

      final line = csvToReceipts(csv).receipts.single.lines.single;

      expect(line.itemName, 'Bolt');
      expect(line.sku, 'B1');
      expect(line.unit, 'pcs');
      expect(line.quantity, 3);
      expect(line.unitPrice, 500);
    });

    // ONE ROW PER LINE, so the rows have to be gathered back into documents.
    // Getting this wrong turns one three-line receipt into three receipts.
    test('a multi-line receipt is one receipt, not three', () {
      final csv = receiptsToCsv([
        _receipt(
          lines: const [
            ReceiptLine(
              id: 'l1',
              itemId: 'i1',
              itemName: 'Bolt',
              quantity: 2,
              unitPrice: 500,
            ),
            ReceiptLine(
              id: 'l2',
              itemId: 'i2',
              itemName: 'Nut',
              quantity: 4,
              unitPrice: 100,
            ),
            ReceiptLine(
              id: 'l3',
              itemId: 'i3',
              itemName: 'Washer',
              quantity: 6,
              unitPrice: 50,
            ),
          ],
        ),
      ], _settings);

      final result = csvToReceipts(csv);

      expect(result.receipts, hasLength(1));
      expect(result.receipts.single.lines, hasLength(3));
      expect(result.receipts.single.lines.map((l) => l.itemName), [
        'Bolt',
        'Nut',
        'Washer',
      ]);
    });

    test('several receipts stay several receipts', () {
      final csv = receiptsToCsv([
        _receipt(reference: 'RC-0001'),
        _receipt(reference: 'RC-0002'),
        _receipt(reference: 'RC-0003'),
      ], _settings);

      final result = csvToReceipts(csv);

      expect(result.receipts.map((r) => r.reference), [
        'RC-0001',
        'RC-0002',
        'RC-0003',
      ]);
    });

    test('a receipt with no lines still comes back', () {
      // The exporter writes a row for one so a voided receipt does not vanish;
      // the importer has to recognise that row as a receipt, not a bad line.
      final csv = receiptsToCsv([_receipt(lines: const [])], _settings);

      final result = csvToReceipts(csv);

      expect(result.receipts, hasLength(1));
      expect(result.receipts.single.lines, isEmpty);
      expect(result.errors, isEmpty);
    });

    test('a refunded quantity survives', () {
      final csv = receiptsToCsv([
        _receipt(
          lines: const [
            ReceiptLine(
              id: 'l1',
              itemId: 'i1',
              itemName: 'Bolt',
              quantity: 5,
              unitPrice: 500,
              quantityRefunded: 2,
            ),
          ],
        ),
      ], _settings);

      expect(
        csvToReceipts(csv).receipts.single.lines.single.quantityRefunded,
        2,
      );
    });
  });

  group('a sheet somebody edited by hand', () {
    test('a row with no reference is reported, not silently dropped', () {
      const csv =
          'reference,item,quantity,unitPrice\n'
          ',Bolt,2,500\n'
          'RC-0002,Nut,1,100\n';

      final result = csvToReceipts(csv);

      expect(result.receipts, hasLength(1));
      expect(result.errors.single, contains('Row 2'));
    });

    test('a line with no quantity is reported', () {
      const csv =
          'reference,item,quantity,unitPrice\n'
          'RC-0001,Bolt,0,500\n';

      final result = csvToReceipts(csv);

      expect(result.errors.single, contains('Bolt'));
      expect(result.receipts.single.lines, isEmpty);
    });

    test('an unreadable date is reported and the receipt still imports', () {
      const csv =
          'reference,issuedAt,item,quantity,unitPrice\n'
          'RC-0001,not-a-date,Bolt,2,500\n';

      final result = csvToReceipts(csv);

      expect(result.errors.single, contains('not-a-date'));
      expect(result.receipts, hasLength(1));
    });

    test('a file with no reference column says which column is missing', () {
      const csv = 'item,quantity\nBolt,2\n';

      final result = csvToReceipts(csv);

      expect(result.receipts, isEmpty);
      expect(result.errors.single, contains('reference'));
    });

    test('an empty file says so', () {
      expect(csvToReceipts('').errors.single, contains('no data rows'));
    });

    test('rows for one receipt need not be adjacent', () {
      // Sorting a sheet by item name in a spreadsheet splits them up.
      const csv =
          'reference,item,quantity,unitPrice\n'
          'RC-0001,Bolt,2,500\n'
          'RC-0002,Nut,1,100\n'
          'RC-0001,Washer,4,50\n';

      final result = csvToReceipts(csv);

      expect(result.receipts, hasLength(2));
      expect(
        result.receipts.firstWhere((r) => r.reference == 'RC-0001').lines,
        hasLength(2),
      );
    });

    test('currency symbols and thousands separators are read as numbers', () {
      const csv =
          'reference,item,quantity,unitPrice\n'
          'RC-0001,Bolt,2,"₦1,500.50"\n';

      expect(
        csvToReceipts(csv).receipts.single.lines.single.unitPrice,
        1500.50,
      );
    });
  });
}
