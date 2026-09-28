import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/models/party.dart';

import 'support.dart';

Supplier supplierDraft({String name = 'Nexa Components', int leadTime = 7}) {
  final now = DateTime.now();
  return Supplier(
    id: '',
    name: name,
    contactName: 'Ada',
    phone: '0801',
    leadTimeDays: leadTime,
    createdAt: now,
    updatedAt: now,
  );
}

Customer customerDraft({
  String name = 'Kola Stores',
  PriceTier tier = PriceTier.retailer,
}) {
  final now = DateTime.now();
  return Customer(
    id: '',
    name: name,
    priceTier: tier,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('suppliers', () {
    test('creating one gives it an id and keeps the list sorted', () async {
      final c = await newController();

      await c.createSupplier(supplierDraft(name: 'Zenith Parts'));
      await c.createSupplier(supplierDraft(name: 'Apex Metals'));

      expect(c.suppliers.map((s) => s.name), ['Apex Metals', 'Zenith Parts']);
      expect(c.suppliers.first.id, isNotEmpty);
    });

    test('an item can be linked to one and reads back its name', () async {
      final c = await newController();
      final supplier = await c.createSupplier(supplierDraft());
      final item = await c.createItem(
        draft().copyWith(supplierId: supplier.id),
      );

      expect(c.supplierNameFor(c.byId(item.id)!), 'Nexa Components');
      expect(c.itemCountForSupplier(supplier.id), 1);
    });

    // Archiving, not deleting: purchase orders reference suppliers and those
    // references have to stay resolvable, so the app archives and there is no
    // delete. This used to test a `deleteSupplier` the UI never called.
    test(
      'archiving one unlinks its items but keeps the name as text',
      () async {
        final c = await newController();
        final supplier = await c.createSupplier(supplierDraft());
        final item = await c.createItem(
          draft().copyWith(supplierId: supplier.id),
        );

        await c.archiveSupplier(supplier.id);

        final after = c.byId(item.id)!;
        expect(after.supplierId, isNull, reason: 'no dangling reference');
        expect(
          after.supplier,
          'Nexa Components',
          reason: 'history stays readable',
        );
        expect(c.suppliers, isEmpty);
      },
    );
  });

  group('customers', () {
    test('an unknown tier in storage falls back to retailer', () {
      expect(priceTierFrom('nonsense'), PriceTier.retailer);
      expect(priceTierFrom(null), PriceTier.retailer);
      expect(priceTierFrom('distributor'), PriceTier.distributor);
    });

    test('archiving one takes it out of the pickers', () async {
      final c = await newController();
      final customer = await c.createCustomer(customerDraft());

      final archived = await c.archiveCustomer(customer.id);

      expect(archived, isTrue);
      expect(c.customers, isEmpty);
    });
  });
}
