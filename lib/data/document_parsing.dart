import '../models/invoice.dart';
import '../models/party.dart';
import '../models/purchase_order.dart';
import '../models/receipt.dart';
import '../models/sales_order.dart';
import '../models/transfer.dart';

/// Reads documents back from the API.
///
/// The models carry `toJson` because they were written for backups, but never
/// needed the other direction while they only ever came out of drift. The
/// server sends exactly the shape `toJson` produces, so these are its inverse.
///
/// Tolerant in the same way `Item.fromJson` is: a missing or wrongly-typed
/// field degrades to the model's own default rather than failing the whole
/// load. One malformed document must not blank the screen.

Invoice invoiceFromJson(Map<String, dynamic> json) => Invoice(
  id: str(json['id']),
  reference: str(json['reference']),
  salesOrderId: nullableStr(json['salesOrderId']),
  customerId: nullableStr(json['customerId']),
  customerName: str(json['customerName']),
  status: invoiceStatusFrom(nullableStr(json['status'])),
  lines: [
    for (final line in list(json['lines']))
      InvoiceLine(
        id: str(line['id']),
        itemId: str(line['itemId']),
        itemName: str(line['itemName']),
        sku: str(line['sku']),
        unit: str(line['unit'], fallback: 'pcs'),
        quantity: integer(line['quantity']),
        unitPrice: decimal(line['unitPrice']),
        discount: decimal(line['discount']),
        costOfGoods: decimal(line['costOfGoods']),
      ),
  ],
  discount: decimal(json['discount']),
  taxRate: decimal(json['taxRate']),
  taxLabel: str(json['taxLabel'], fallback: 'Tax'),
  amountPaid: decimal(json['amountPaid']),
  terms: str(json['terms']),
  notes: str(json['notes']),
  movesStock: json['movesStock'] != false,
  issuedAt: date(json['issuedAt']) ?? DateTime.now(),
  dueAt: date(json['dueAt']),
  closedAt: date(json['closedAt']),
  cancelledReason: str(json['cancelledReason']),
  createdAt: date(json['createdAt']) ?? DateTime.now(),
  updatedAt: date(json['updatedAt']) ?? DateTime.now(),
);

Receipt receiptFromJson(Map<String, dynamic> json) => Receipt(
  id: str(json['id']),
  reference: str(json['reference']),
  salesOrderId: nullableStr(json['salesOrderId']),
  invoiceId: nullableStr(json['invoiceId']),
  customerId: nullableStr(json['customerId']),
  customerName: str(json['customerName']),
  status: receiptStatusFrom(nullableStr(json['status'])),
  method: paymentMethodFrom(nullableStr(json['method'])),
  lines: [
    for (final line in list(json['lines']))
      ReceiptLine(
        id: str(line['id']),
        itemId: str(line['itemId']),
        itemName: str(line['itemName']),
        sku: str(line['sku']),
        unit: str(line['unit'], fallback: 'pcs'),
        quantity: integer(line['quantity']),
        unitPrice: decimal(line['unitPrice']),
        discount: decimal(line['discount']),
        quantityRefunded: integer(line['quantityRefunded']),
        costOfGoods: decimal(line['costOfGoods']),
      ),
  ],
  discount: decimal(json['discount']),
  taxRate: decimal(json['taxRate']),
  taxLabel: str(json['taxLabel'], fallback: 'Tax'),
  amountPaid: decimal(json['amountPaid']),
  notes: str(json['notes']),
  cashier: str(json['cashier']),
  movesStock: json['movesStock'] != false,
  issuedAt: date(json['issuedAt']) ?? DateTime.now(),
  refundedAt: date(json['refundedAt']),
  voidedAt: date(json['voidedAt']),
  voidReason: str(json['voidReason']),
  createdAt: date(json['createdAt']) ?? DateTime.now(),
  updatedAt: date(json['updatedAt']) ?? DateTime.now(),
);

PurchaseOrder purchaseOrderFromJson(Map<String, dynamic> json) => PurchaseOrder(
  id: str(json['id']),
  reference: str(json['reference']),
  supplierId: nullableStr(json['supplierId']),
  supplierName: str(json['supplierName']),
  status: purchaseStatusFrom(nullableStr(json['status'])),
  orderedAt: date(json['orderedAt']),
  expectedAt: date(json['expectedAt']),
  closedAt: date(json['closedAt']),
  notes: str(json['notes']),
  lines: [
    for (final line in list(json['lines']))
      PurchaseOrderLine(
        id: str(line['id']),
        itemId: str(line['itemId']),
        itemName: str(line['itemName']),
        quantityOrdered: integer(line['quantityOrdered']),
        quantityReceived: integer(line['quantityReceived']),
        unitCost: decimal(line['unitCost']),
      ),
  ],
  createdAt: date(json['createdAt']) ?? DateTime.now(),
  updatedAt: date(json['updatedAt']) ?? DateTime.now(),
);

SalesOrder salesOrderFromJson(Map<String, dynamic> json) => SalesOrder(
  id: str(json['id']),
  reference: str(json['reference']),
  customerId: nullableStr(json['customerId']),
  customerName: str(json['customerName']),
  priceTier: priceTierFrom(nullableStr(json['priceTier'])),
  status: salesStatusFrom(nullableStr(json['status'])),
  confirmedAt: date(json['confirmedAt']),
  dueAt: date(json['dueAt']),
  closedAt: date(json['closedAt']),
  notes: str(json['notes']),
  lines: [
    for (final line in list(json['lines']))
      SalesOrderLine(
        id: str(line['id']),
        itemId: str(line['itemId']),
        itemName: str(line['itemName']),
        quantityOrdered: integer(line['quantityOrdered']),
        quantityFulfilled: integer(line['quantityFulfilled']),
        unitPrice: decimal(line['unitPrice']),
        costOfGoods: decimal(line['costOfGoods']),
      ),
  ],
  createdAt: date(json['createdAt']) ?? DateTime.now(),
  updatedAt: date(json['updatedAt']) ?? DateTime.now(),
);

Transfer transferFromJson(Map<String, dynamic> json) => Transfer(
  id: str(json['id']),
  reference: str(json['reference']),
  fromLocation: str(json['fromLocation']),
  toLocation: str(json['toLocation']),
  notes: str(json['notes']),
  lines: [
    for (final line in list(json['lines']))
      TransferLine(
        id: str(line['id']),
        itemId: str(line['itemId']),
        itemName: str(line['itemName']),
        quantity: integer(line['quantity']),
      ),
  ],
  movedAt: date(json['movedAt']) ?? DateTime.now(),
  createdAt: date(json['createdAt']) ?? DateTime.now(),
);

// --------------------------------------------------------------------

List<Map<String, dynamic>> list(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map) entry.cast<String, dynamic>(),
  ];
}

String str(Object? value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

String? nullableStr(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int integer(Object? value) => value is num ? value.toInt() : 0;

double decimal(Object? value) => value is num ? value.toDouble() : 0;

/// Parsed as sent — the server always writes UTC with the trailing `Z` — and
/// returned local, because every screen shows these to a person.
DateTime? date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}
