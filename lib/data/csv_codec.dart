import '../models/item.dart';
import '../models/movement.dart';
import '../models/party.dart';
import '../models/receipt.dart';

const _itemColumns = [
  'name',
  'sku',
  'barcode',
  'category',
  'location',
  'quantity',
  'reorderLevel',
  'unit',
  'unitCost',
  'retailerPrice',
  'distributorPrice',
  'supplier',
  'notes',
];

String _escape(Object? value) {
  final s = value?.toString() ?? '';
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

String itemsToCsv(List<Item> items) {
  final rows = items.map((i) {
    final cells = <Object?>[
      i.name,
      i.sku,
      i.barcode,
      i.category,
      i.location,
      i.quantity,
      i.reorderLevel,
      i.unit,
      i.unitCost,
      i.retailerPrice,
      i.distributorPrice,
      i.supplier,
      i.notes,
    ];
    return cells.map(_escape).join(',');
  });
  return [_itemColumns.join(','), ...rows].join('\n');
}

String movementsToCsv(List<Movement> movements) {
  const header = ['date', 'item', 'type', 'change', 'before', 'after', 'note'];
  final rows = movements.map((m) {
    final cells = <Object?>[
      m.at.toIso8601String(),
      m.itemName,
      m.kind.name,
      m.delta,
      m.before,
      m.after,
      m.note,
    ];
    return cells.map(_escape).join(',');
  });
  return [header.join(','), ...rows].join('\n');
}

/// Minimal RFC-4180 parser: quoted cells, escaped quotes and CRLF line ends.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];

    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }

    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      // Swallow the LF of a CRLF pair.
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }

  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }

  return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
}

class ItemDraft {
  const ItemDraft({
    required this.name,
    required this.sku,
    required this.barcode,
    required this.category,
    required this.location,
    required this.quantity,
    required this.reorderLevel,
    required this.unit,
    required this.unitCost,
    required this.retailerPrice,
    required this.distributorPrice,
    required this.supplier,
    required this.notes,
  });

  final String name;
  final String sku;
  final String barcode;
  final String category;
  final String location;
  final int quantity;
  final int reorderLevel;
  final String unit;
  final double unitCost;
  final double retailerPrice;
  final double distributorPrice;
  final String supplier;
  final String notes;
}

class ImportResult {
  const ImportResult(this.items, this.errors);
  final List<ItemDraft> items;
  final List<String> errors;
}

/// Maps a sheet to drafts by header name. Unknown columns are ignored and
/// missing ones fall back to defaults, so a hand-made sheet still imports.
ImportResult csvToItems(String text) {
  final rows = parseCsv(text);
  if (rows.length < 2) {
    return const ImportResult([], ['The file has no data rows.']);
  }

  final header = rows.first
      .map((h) => h.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), ''))
      .toList();
  int col(String name) => header.indexOf(name);

  final iName = col('name');
  if (iName == -1) {
    return const ImportResult([], [
      'No "name" column found. That column is required.',
    ]);
  }

  final iSku = col('sku');
  final iBarcode = col('barcode');
  final iCategory = col('category');
  final iLocation = col('location');
  final iQuantity = col('quantity');
  final iReorder = col('reorderlevel');
  final iUnit = col('unit');
  final iCost = col('unitcost');
  final iRetailer = col('retailerprice');
  // A sheet exported before the split had one "unitPrice" (or a hand-written
  // "salePrice"); either is read as the distributor figure.
  final iDistributor = [
    col('distributorprice'),
    col('unitprice'),
    col('saleprice'),
  ].firstWhere((i) => i != -1, orElse: () => -1);
  final iSupplier = col('supplier');
  final iNotes = col('notes');

  String cell(List<String> row, int i) =>
      (i == -1 || i >= row.length) ? '' : row[i].trim();

  double num_(List<String> row, int i) {
    final raw = cell(row, i).replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(raw) ?? 0;
  }

  final items = <ItemDraft>[];
  final errors = <String>[];

  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final name = cell(row, iName);
    if (name.isEmpty) {
      errors.add('Row ${r + 1}: skipped, no name.');
      continue;
    }
    final unit = cell(row, iUnit);
    items.add(
      ItemDraft(
        name: name,
        sku: cell(row, iSku),
        barcode: cell(row, iBarcode),
        category: cell(row, iCategory),
        location: cell(row, iLocation),
        quantity: num_(row, iQuantity).round(),
        reorderLevel: num_(row, iReorder).round(),
        unit: unit.isEmpty ? 'pcs' : unit,
        unitCost: num_(row, iCost),
        retailerPrice: num_(row, iRetailer),
        distributorPrice: num_(row, iDistributor),
        supplier: cell(row, iSupplier),
        notes: cell(row, iNotes),
      ),
    );
  }

  return ImportResult(items, errors);
}

/// One receipt rebuilt from a sheet, with the lines that belonged to it.
class ReceiptDraft {
  const ReceiptDraft({
    required this.reference,
    required this.issuedAt,
    required this.customerName,
    required this.method,
    required this.lines,
    this.notes = '',
    this.taxLabel = 'VAT',
    this.taxRate = 0,
    this.discount = 0,
    this.amountPaid = 0,
  });

  final String reference;
  final DateTime issuedAt;
  final String customerName;
  final PaymentMethod method;
  final List<ReceiptLine> lines;
  final String notes;
  final String taxLabel;
  final double taxRate;
  final double discount;
  final double amountPaid;
}

class ReceiptImportResult {
  const ReceiptImportResult(this.receipts, this.errors);
  final List<ReceiptDraft> receipts;
  final List<String> errors;
}

/// Rebuilds receipts from the sheet [receiptsToCsv] writes.
///
/// ONE ROW PER LINE, so the rows have to be gathered back into documents:
/// every row repeats its receipt's reference, totals and customer, and the
/// columns that differ are the item ones. Rows are grouped by reference in the
/// order they appear, which keeps a hand-edited sheet importable as long as a
/// receipt's rows stay together — and tolerates them not being, since grouping
/// is by key rather than by adjacency.
///
/// Totals are NOT read back. They are derived from the lines, the discount and
/// the tax rate, and a sheet someone has edited will have a stale total in it
/// far more often than a wrong line. Reading the total would import an
/// arithmetic that disagrees with the lines printed beside it.
ReceiptImportResult csvToReceipts(String text) {
  final rows = parseCsv(text);
  if (rows.length < 2) {
    return const ReceiptImportResult([], ['The file has no data rows.']);
  }

  final header = rows.first
      .map((h) => h.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), ''))
      .toList();
  int col(String name) => header.indexOf(name);

  final iReference = col('reference');
  if (iReference == -1) {
    return const ReceiptImportResult([], [
      'No "reference" column found. That column is required.',
    ]);
  }

  final iIssued = col('issuedat');
  final iCustomer = col('customer');
  final iMethod = col('paymentmethod');
  final iItem = col('item');
  final iSku = col('sku');
  final iQuantity = col('quantity');
  final iUnit = col('unit');
  final iUnitPrice = col('unitprice');
  final iLineDiscount = col('linediscount');
  final iRefunded = col('quantityrefunded');
  final iDiscount = col('receiptdiscount');
  final iTaxLabel = col('taxlabel');
  final iTaxRate = col('taxrate');
  final iPaid = col('amountpaid');
  final iNotes = col('notes');

  String cell(List<String> row, int i) =>
      (i == -1 || i >= row.length) ? '' : row[i].trim();

  double num_(List<String> row, int i) {
    final raw = cell(row, i).replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(raw) ?? 0;
  }

  int int_(List<String> row, int i) => num_(row, i).round();

  final byReference = <String, ReceiptDraft>{};
  final linesByReference = <String, List<ReceiptLine>>{};
  final errors = <String>[];
  var lineId = 0;

  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((c) => c.trim().isEmpty)) continue;

    final reference = cell(row, iReference);
    if (reference.isEmpty) {
      errors.add('Row ${r + 1}: no receipt reference, so it was skipped.');
      continue;
    }

    final issuedRaw = cell(row, iIssued);
    final issuedAt = DateTime.tryParse(issuedRaw);
    if (issuedAt == null && issuedRaw.isNotEmpty) {
      errors.add('Row ${r + 1}: "$issuedRaw" is not a date it could read.');
    }

    byReference.putIfAbsent(
      reference,
      () => ReceiptDraft(
        reference: reference,
        issuedAt: issuedAt ?? DateTime.now(),
        customerName: cell(row, iCustomer),
        method: paymentMethodFrom(cell(row, iMethod)),
        lines: const [],
        notes: cell(row, iNotes),
        taxLabel: cell(row, iTaxLabel).isEmpty ? 'VAT' : cell(row, iTaxLabel),
        taxRate: num_(row, iTaxRate),
        discount: num_(row, iDiscount),
        amountPaid: num_(row, iPaid),
      ),
    );

    // A receipt with no lines still gets a row on the way out, so a blank item
    // here is that row rather than a mistake.
    final itemName = cell(row, iItem);
    if (itemName.isEmpty) continue;

    final quantity = int_(row, iQuantity);
    if (quantity <= 0) {
      errors.add(
        'Row ${r + 1}: "$itemName" has no quantity, so it was left out.',
      );
      continue;
    }

    linesByReference
        .putIfAbsent(reference, () => [])
        .add(
          ReceiptLine(
            id: 'csv-${lineId++}',
            // The sheet carries a name, not an id: an imported receipt is history
            // being brought across, and the item it names may not exist here.
            itemId: '',
            itemName: itemName,
            sku: cell(row, iSku),
            unit: cell(row, iUnit),
            quantity: quantity,
            unitPrice: num_(row, iUnitPrice),
            discount: num_(row, iLineDiscount),
            quantityRefunded: int_(row, iRefunded).clamp(0, quantity),
          ),
        );
  }

  final receipts = [
    for (final entry in byReference.entries)
      ReceiptDraft(
        reference: entry.key,
        issuedAt: entry.value.issuedAt,
        customerName: entry.value.customerName,
        method: entry.value.method,
        lines: linesByReference[entry.key] ?? const [],
        notes: entry.value.notes,
        taxLabel: entry.value.taxLabel,
        taxRate: entry.value.taxRate,
        discount: entry.value.discount,
        amountPaid: entry.value.amountPaid,
      ),
  ];

  return ReceiptImportResult(receipts, errors);
}

const _customerColumns = [
  'name',
  'contactName',
  'phone',
  'email',
  'address',
  'priceTier',
  'notes',
];

/// Customers as a sheet, in the same columns [csvToCustomers] reads back.
String customersToCsv(List<Customer> customers) {
  final rows = customers.map(
    (c) => <Object?>[
      c.name,
      c.contactName,
      c.phone,
      c.email,
      c.address,
      c.priceTier.name,
      c.notes,
    ].map(_escape).join(','),
  );
  return [_customerColumns.join(','), ...rows].join('\n');
}

class CustomerImportResult {
  const CustomerImportResult(this.customers, this.errors);
  final List<Customer> customers;
  final List<String> errors;
}

/// Maps a sheet to customers by header name, like [csvToItems]: only "name"
/// is required. The price tier reads "distributor" (any case) as distributor
/// and anything else as retailer.
CustomerImportResult csvToCustomers(String text) {
  final rows = parseCsv(text);
  if (rows.length < 2) {
    return const CustomerImportResult([], ['The file has no data rows.']);
  }
  final header = rows.first
      .map((h) => h.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), ''))
      .toList();
  int col(String name) => header.indexOf(name);

  final iName = col('name');
  if (iName == -1) {
    return const CustomerImportResult([], [
      'No "name" column found. That column is required.',
    ]);
  }
  final iContact = [
    col('contactname'),
    col('contact'),
  ].firstWhere((i) => i != -1, orElse: () => -1);
  final iPhone = col('phone');
  final iEmail = col('email');
  final iAddress = col('address');
  final iTier = [
    col('pricetier'),
    col('tier'),
  ].firstWhere((i) => i != -1, orElse: () => -1);
  final iNotes = col('notes');

  String cell(List<String> row, int i) =>
      (i == -1 || i >= row.length) ? '' : row[i].trim();

  final now = DateTime.now();
  final customers = <Customer>[];
  final errors = <String>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final name = cell(row, iName);
    if (name.isEmpty) {
      errors.add('Row ${r + 1}: skipped, no name.');
      continue;
    }
    customers.add(
      Customer(
        id: '',
        name: name,
        contactName: cell(row, iContact),
        phone: cell(row, iPhone),
        email: cell(row, iEmail),
        address: cell(row, iAddress),
        priceTier: cell(row, iTier).toLowerCase().startsWith('dist')
            ? PriceTier.distributor
            : PriceTier.retailer,
        notes: cell(row, iNotes),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  return CustomerImportResult(customers, errors);
}
