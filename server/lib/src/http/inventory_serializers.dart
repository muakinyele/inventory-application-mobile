import '../db/database.dart';

/// JSON for the inventory rows.
///
/// Field names match the client's existing model classes exactly, so the
/// client's `fromJson` needs no translation layer when it stops reading its
/// own database and starts reading these.
///
/// Timestamps are ISO-8601 UTC with the `Z`, never a bare local string: the
/// client parses these on devices in other zones, and a bare date there is a
/// different instant.

Map<String, Object?> itemJson(Item item) => {
  'id': item.id,
  'name': item.name,
  'sku': item.sku,
  'barcode': item.barcode,
  'category': item.category,
  'location': item.location,
  'quantity': item.quantity,
  'reorderLevel': item.reorderLevel,
  'unit': item.unit,
  'unitCost': item.unitCost,
  'retailerPrice': item.retailerPrice,
  'distributorPrice': item.distributorPrice,
  'supplier': item.supplier,
  'supplierId': item.supplierId,
  'unitsPerPack': item.unitsPerPack,
  'notes': item.notes,
  'photo': item.photo,
  'createdAt': item.createdAt.toUtc().toIso8601String(),
  'updatedAt': item.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> stockJson(StockLevel row) => {
  'itemId': row.itemId,
  'location': row.location,
  'quantity': row.quantity,
};

Map<String, Object?> movementJson(Movement movement) => {
  'id': movement.id,
  'itemId': movement.itemId,
  'itemName': movement.itemName,
  'kind': movement.kind,
  'before': movement.before,
  'after': movement.after,
  'note': movement.note,
  'actor': movement.actor,
  'documentId': movement.documentId,
  'at': movement.at.toUtc().toIso8601String(),
};

Map<String, Object?> supplierJson(Supplier supplier) => {
  'id': supplier.id,
  'name': supplier.name,
  'contactName': supplier.contactName,
  'phone': supplier.phone,
  'email': supplier.email,
  'address': supplier.address,
  'leadTimeDays': supplier.leadTimeDays,
  'paymentTerms': supplier.paymentTerms,
  'notes': supplier.notes,
  'archived': supplier.archived,
  'createdAt': supplier.createdAt.toUtc().toIso8601String(),
  'updatedAt': supplier.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> customerJson(Customer customer) => {
  'id': customer.id,
  'name': customer.name,
  'contactName': customer.contactName,
  'phone': customer.phone,
  'email': customer.email,
  'address': customer.address,
  'priceTier': customer.priceTier,
  'notes': customer.notes,
  'archived': customer.archived,
  'createdAt': customer.createdAt.toUtc().toIso8601String(),
  'updatedAt': customer.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> categoryJson(Category category) => {
  'name': category.name,
  'swatchIndex': category.swatchIndex,
  'position': category.position,
};

Map<String, Object?> lookupJson(Lookup lookup) => {
  'kind': lookup.kind,
  'value': lookup.value,
  'position': lookup.position,
};

// --------------------------------------------------------------------
// Documents
// --------------------------------------------------------------------

Map<String, Object?> invoiceJson(Invoice invoice, List<InvoiceLine> lines) => {
  'id': invoice.id,
  'reference': invoice.reference,
  'salesOrderId': invoice.salesOrderId,
  'customerId': invoice.customerId,
  'customerName': invoice.customerName,
  'status': invoice.status,
  'discount': invoice.discount,
  'taxRate': invoice.taxRate,
  'taxLabel': invoice.taxLabel,
  'amountPaid': invoice.amountPaid,
  'terms': invoice.terms,
  'notes': invoice.notes,
  'movesStock': invoice.movesStock,
  'issuedAt': invoice.issuedAt.toUtc().toIso8601String(),
  'dueAt': invoice.dueAt?.toUtc().toIso8601String(),
  'closedAt': invoice.closedAt?.toUtc().toIso8601String(),
  'cancelledReason': invoice.cancelledReason,
  'createdAt': invoice.createdAt.toUtc().toIso8601String(),
  'updatedAt': invoice.updatedAt.toUtc().toIso8601String(),
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'itemId': line.itemId,
        'itemName': line.itemName,
        'sku': line.sku,
        'unit': line.unit,
        'quantity': line.quantity,
        'unitPrice': line.unitPrice,
        'discount': line.discount,
        'costOfGoods': line.costOfGoods,
        'position': line.position,
      },
  ],
};

Map<String, Object?> receiptJson(Receipt receipt, List<ReceiptLine> lines) => {
  'id': receipt.id,
  'reference': receipt.reference,
  'salesOrderId': receipt.salesOrderId,
  'invoiceId': receipt.invoiceId,
  'customerId': receipt.customerId,
  'customerName': receipt.customerName,
  'status': receipt.status,
  'method': receipt.method,
  'discount': receipt.discount,
  'taxRate': receipt.taxRate,
  'taxLabel': receipt.taxLabel,
  'amountPaid': receipt.amountPaid,
  'notes': receipt.notes,
  'cashier': receipt.cashier,
  'movesStock': receipt.movesStock,
  'issuedAt': receipt.issuedAt.toUtc().toIso8601String(),
  'refundedAt': receipt.refundedAt?.toUtc().toIso8601String(),
  'voidedAt': receipt.voidedAt?.toUtc().toIso8601String(),
  'voidReason': receipt.voidReason,
  'createdAt': receipt.createdAt.toUtc().toIso8601String(),
  'updatedAt': receipt.updatedAt.toUtc().toIso8601String(),
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'itemId': line.itemId,
        'itemName': line.itemName,
        'sku': line.sku,
        'unit': line.unit,
        'quantity': line.quantity,
        'unitPrice': line.unitPrice,
        'discount': line.discount,
        'quantityRefunded': line.quantityRefunded,
        'costOfGoods': line.costOfGoods,
        'position': line.position,
      },
  ],
};

Map<String, Object?> purchaseOrderJson(
  PurchaseOrder order,
  List<PurchaseOrderLine> lines,
) => {
  'id': order.id,
  'reference': order.reference,
  'supplierId': order.supplierId,
  'supplierName': order.supplierName,
  'status': order.status,
  'orderedAt': order.orderedAt?.toUtc().toIso8601String(),
  'expectedAt': order.expectedAt?.toUtc().toIso8601String(),
  'closedAt': order.closedAt?.toUtc().toIso8601String(),
  'notes': order.notes,
  'createdAt': order.createdAt.toUtc().toIso8601String(),
  'updatedAt': order.updatedAt.toUtc().toIso8601String(),
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'itemId': line.itemId,
        'itemName': line.itemName,
        'quantityOrdered': line.quantityOrdered,
        'quantityReceived': line.quantityReceived,
        'unitCost': line.unitCost,
        'position': line.position,
      },
  ],
};

Map<String, Object?> salesOrderJson(
  SalesOrder order,
  List<SalesOrderLine> lines,
) => {
  'id': order.id,
  'reference': order.reference,
  'customerId': order.customerId,
  'customerName': order.customerName,
  'priceTier': order.priceTier,
  'status': order.status,
  'confirmedAt': order.confirmedAt?.toUtc().toIso8601String(),
  'dueAt': order.dueAt?.toUtc().toIso8601String(),
  'closedAt': order.closedAt?.toUtc().toIso8601String(),
  'notes': order.notes,
  'createdAt': order.createdAt.toUtc().toIso8601String(),
  'updatedAt': order.updatedAt.toUtc().toIso8601String(),
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'itemId': line.itemId,
        'itemName': line.itemName,
        'quantityOrdered': line.quantityOrdered,
        'quantityFulfilled': line.quantityFulfilled,
        'unitPrice': line.unitPrice,
        'costOfGoods': line.costOfGoods,
        'position': line.position,
      },
  ],
};

Map<String, Object?> transferJson(
  Transfer transfer,
  List<TransferLine> lines,
) => {
  'id': transfer.id,
  'reference': transfer.reference,
  'fromLocation': transfer.fromLocation,
  'toLocation': transfer.toLocation,
  'notes': transfer.notes,
  'movedAt': transfer.movedAt.toUtc().toIso8601String(),
  'createdAt': transfer.createdAt.toUtc().toIso8601String(),
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'itemId': line.itemId,
        'itemName': line.itemName,
        'quantity': line.quantity,
        'position': line.position,
      },
  ],
};
