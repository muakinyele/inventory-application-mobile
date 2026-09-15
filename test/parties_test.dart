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

    test('deleting one unlinks its items but keeps the name as text', () async {
      final c = await newController();
      final supplier = await c.createSupplier(supplierDraft());
      final item = await c.createItem(
        draft().copyWith(supplierId: supplier.id),
      );

      c.deleteSupplier(supplier.id);

      final after = c.byId(item.id)!;
      expect(after.supplierId, isNull, reason: 'no dangling reference');
      expect(
        after.supplier,
        'Nexa Components',
        reason: 'history stays readable',
      );
      expect(c.suppliers, isEmpty);
    });

    test('the unlinking survives a reload', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final supplier = await c.createSupplier(supplierDraft());
      await c.createItem(draft().copyWith(supplierId: supplier.id));
      await pumpWrites();

      c.deleteSupplier(supplier.id);
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.suppliers, isEmpty);
      expect(reloaded.items.single.supplierId, isNull);
      expect(reloaded.items.single.supplier, 'Nexa Components');
    });

    test('editing keeps the id and persists', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);
      final supplier = await c.createSupplier(supplierDraft(leadTime: 7));

      await c.updateSupplier(supplier.id, supplier.copyWith(leadTimeDays: 21));
      await pumpWrites();

      final reloaded = await repo.load();
      expect(reloaded.suppliers.single.id, supplier.id);
      expect(reloaded.suppliers.single.leadTimeDays, 21);
    });
  });

  group('customers', () {
    test('a price tier round-trips through the database', () async {
      final repo = newRepository();
      final c = await controllerOver(repo);

      await c.createCustomer(customerDraft(tier: PriceTier.distributor));
      await pumpWrites();

      expect(
        (await repo.load()).customers.single.priceTier,
        PriceTier.distributor,
      );
    });

    test('an unknown tier in storage falls back to retailer', () {
      expect(priceTierFrom('nonsense'), PriceTier.retailer);
      expect(priceTierFrom(null), PriceTier.retailer);
      expect(priceTierFrom('distributor'), PriceTier.distributor);
    });

    test('deleting one removes it', () async {
      final c = await newController();
      final customer = await c.createCustomer(customerDraft());

      c.deleteCustomer(customer.id);

      expect(c.customers, isEmpty);
    });
  });

  test('units per pack defaults to one and persists', () async {
    final repo = newRepository();
    final c = await controllerOver(repo);

    await c.createItem(draft(name: 'Loose'));
    await c.createItem(draft(name: 'Carton').copyWith(unitsPerPack: 24));
    await pumpWrites();

    final items = (await repo.load()).items;
    expect(items.firstWhere((i) => i.name == 'Loose').unitsPerPack, 1);
    expect(items.firstWhere((i) => i.name == 'Carton').unitsPerPack, 24);
  });
}
