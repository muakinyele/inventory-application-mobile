import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockpile/app.dart';
import 'package:stockpile/data/sales_order_document.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/models/sales_order.dart';
import 'package:stockpile/state/inventory_controller.dart';

import 'support.dart';

const _settings = AppSettings(
  companyName: 'Chedra Olympas',
  currency: 'NGN',
  companyPhone: '+234 802 123 4567',
  taxRate: 0.075,
  taxLabel: 'VAT',
  receiptFooter: 'Thank you for your custom.',
);

SalesOrder _sale({
  SalesStatus status = SalesStatus.partial,
  String notes = 'Deliver after 2pm.',
  List<SalesOrderLine>? lines,
}) => SalesOrder(
  id: 'so1',
  reference: 'SO-0021',
  customerName: 'Ada Nwosu',
  status: status,
  confirmedAt: DateTime.utc(2026, 9, 22),
  dueAt: DateTime.utc(2026, 10, 1),
  notes: notes,
  lines:
      lines ??
      const [
        SalesOrderLine(
          id: 'l1',
          itemId: 'i1',
          itemName: 'Bolt',
          quantityOrdered: 10,
          quantityFulfilled: 4,
          unitPrice: 60,
        ),
      ],
  createdAt: DateTime.utc(2026, 9, 20),
  updatedAt: DateTime.utc(2026, 9, 22),
);

final _bolt = Item(
  id: 'i1',
  name: 'Bolt',
  sku: 'BLT-10',
  unit: 'pcs',
  quantity: 50,
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the sales order document', () {
    test('it renders to a real PDF', () async {
      final bytes = await SalesOrderDocument(
        _sale(),
        _settings,
        itemById: (id) => id == 'i1' ? _bolt : null,
      ).toPdf();

      expect(bytes.length, greaterThan(1000));
      expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    });

    test('a cancelled order and one with no lines still render', () async {
      for (final order in [
        _sale(status: SalesStatus.cancelled),
        _sale(status: SalesStatus.draft, notes: '', lines: const []),
      ]) {
        final bytes = await SalesOrderDocument(order, _settings).toPdf();
        expect(bytes.length, greaterThan(1000));
      }
    });

    test('the filename carries the reference and the date', () {
      expect(
        SalesOrderDocument(_sale(), _settings).filename('pdf'),
        'SO-0021-20260922.pdf',
      );
    });

    test('the message carries the lines, the tax and the total', () {
      final summary = SalesOrderDocument(_sale(), _settings).summary();

      expect(summary, contains('Chedra Olympas — sales order SO-0021'));
      expect(summary, contains('Customer: Ada Nwosu'));
      expect(summary, contains('10 × Bolt'));
      // 600 + 7.5% VAT = 645, the figure an invoice from it will carry.
      expect(summary, contains('VAT'));
      expect(summary, contains('645'));
      expect(summary, contains('Deliver after 2pm.'));
    });
  });

  group('the sales order page', () {
    Future<void> pump(
      WidgetTester tester,
      String location, {
      bool settle = true,
    }) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = await seededController(
        items: [_bolt],
        salesOrders: [_sale()],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<InventoryController>.value(
          value: controller,
          child: StockpileApp(initialLocation: location),
        ),
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        // The preview spins while it renders, which never settles here.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
    }

    testWidgets('offers view, download and share like an invoice', (
      tester,
    ) async {
      await pump(tester, '/sales-orders/so1');

      expect(find.text('View'), findsOne);
      expect(find.text('Download PDF'), findsOne);
      expect(find.text('Share'), findsOne);
    });

    testWidgets('the share sheet can open the document on screen', (
      tester,
    ) async {
      await pump(tester, '/sales-orders/so1');

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(find.text('Sales order SO-0021'), findsOne);
      expect(find.text('View it'), findsOne);
    });

    testWidgets('the view page has its own address', (tester) async {
      await pump(tester, '/sales-orders/so1/view', settle: false);

      expect(find.text('SO-0021'), findsWidgets);
      expect(find.text('Sales order for Ada Nwosu'), findsOne);
      expect(find.text('Download PDF'), findsOne);
    });
  });
}
