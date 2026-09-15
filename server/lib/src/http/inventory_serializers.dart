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
