import 'package:drift/drift.dart' show Value;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../db/database.dart';
import '../../inventory/inventory_service.dart';
import '../api_error.dart';
import '../inventory_serializers.dart';
import '../middleware.dart';
import '../request_context.dart';

/// The shared inventory.
///
/// Every handler opens with its own `request.require(...)`, like the rest of
/// the API: a role that can see stock but not adjust it is expressible without
/// restructuring this file. The permissions themselves already existed — they
/// were written when the RBAC was built and have simply had nothing to guard
/// until now.
Router inventoryRoutes({required InventoryService inventory}) {
  final router = Router();

  // ------------------------------------------------------------------
  // Items
  // ------------------------------------------------------------------
  router.get('/items', (Request request) async {
    request.require('items.view');
    final q = request.url.queryParameters;
    final page = await inventory.listItems(
      search: q['search'],
      category: q['category'],
      location: q['location'],
      supplierId: q['supplier'],
      lowStockOnly: q['low'] == 'true',
      limit: _boundedInt(q['limit'], fallback: 50, min: 1, max: 500),
      offset: _boundedInt(q['offset'], fallback: 0, min: 0, max: 1 << 30),
    );
    return jsonResponse({
      'items': [for (final item in page.items) itemJson(item)],
      'total': page.total,
    });
  });

  router.get('/items/<id>', (Request request, String id) async {
    request.require('items.view');
    final item = await inventory.requireItem(id);
    return jsonResponse({
      'item': itemJson(item),
      'stock': [for (final row in await inventory.stockFor(id)) stockJson(row)],
    });
  });

  router.post('/items', (Request request) async {
    request.require('items.create');
    final body = await readJsonBody(request);
    return jsonResponse({
      'item': itemJson(await inventory.createItem(_itemCompanion(body))),
    }, statusCode: 201);
  });

  router.patch('/items/<id>', (Request request, String id) async {
    request.require('items.update');
    final body = await readJsonBody(request);
    return jsonResponse({
      'item': itemJson(await inventory.updateItem(id, _itemCompanion(body))),
    });
  });

  router.delete('/items/<id>', (Request request, String id) async {
    request.require('items.delete');
    await inventory.deleteItem(id);
    return Response(204);
  });

  /// Empties the inventory. Accounts, roles and the audit trail are left
  /// alone — they are not inventory, and somebody clearing the stock has not
  /// asked to be signed out.
  ///
  /// Behind settings.manage rather than items.delete: this is not a bigger
  /// version of deleting an item, it is a decision about the whole workspace.
  router.delete('/', (Request request) async {
    request.require('settings.manage');
    await inventory.eraseEverything();
    return Response(204);
  });

  // ------------------------------------------------------------------
  // Stock
  // ------------------------------------------------------------------
  router.post('/stock/adjust', (Request request) async {
    final caller = request.require('inventory.adjust');
    final body = await readJsonBody(request);

    final itemId = _requiredString(body, 'itemId');
    final delta = _requiredInt(body, 'delta');

    final result = await inventory.adjustStock(
      itemId: itemId,
      delta: delta,
      kind: body['kind'] as String? ?? 'adjustment',
      actorId: caller.user.id,
      // Optional, but the client always sends it. Without it two people
      // counting the same shelf silently overwrite each other.
      expectedQuantity: (body['expectedQuantity'] as num?)?.toInt(),
      location: body['location'] as String? ?? InventoryService.unassigned,
      note: body['note'] as String? ?? '',
      documentId: body['documentId'] as String?,
    );

    return jsonResponse({
      'item': itemJson(result.item),
      'movement': movementJson(result.movement),
    });
  });

  router.post('/stock/transfer', (Request request) async {
    final caller = request.require('inventory.transfer');
    final body = await readJsonBody(request);

    final rawLines = body['lines'];
    if (rawLines is! List || rawLines.isEmpty) {
      throw ApiError.badRequest('A transfer needs at least one line.');
    }

    final lines = <({String itemId, int quantity})>[];
    for (final raw in rawLines) {
      if (raw is! Map) {
        throw ApiError.badRequest('A transfer line must be an object.');
      }
      final line = raw.cast<String, Object?>();
      lines.add((
        itemId: _requiredString(line, 'itemId'),
        quantity: _requiredInt(line, 'quantity'),
      ));
    }

    final movements = await inventory.transferStock(
      fromLocation: _requiredString(body, 'fromLocation'),
      toLocation: _requiredString(body, 'toLocation'),
      lines: lines,
      actorId: caller.user.id,
      reference: body['reference'] as String? ?? '',
      note: body['note'] as String? ?? '',
    );

    return jsonResponse({
      'movements': [for (final m in movements) movementJson(m)],
    }, statusCode: 201);
  });

  /// Every bin at once, for the initial load.
  router.get('/stock', (Request request) async {
    request.require('items.view');
    final rows = await inventory.allStock();
    return jsonResponse({
      'stock': [for (final row in rows) stockJson(row)],
    });
  });

  // ------------------------------------------------------------------
  // History
  // ------------------------------------------------------------------
  router.get('/movements', (Request request) async {
    request.require('activity.view');
    final q = request.url.queryParameters;
    final rows = await inventory.movements(
      itemId: q['item'],
      limit: _boundedInt(q['limit'], fallback: 100, min: 1, max: 500),
      offset: _boundedInt(q['offset'], fallback: 0, min: 0, max: 1 << 30),
    );
    return jsonResponse({
      'movements': [for (final m in rows) movementJson(m)],
    });
  });

  // ------------------------------------------------------------------
  // Parties
  // ------------------------------------------------------------------
  router.get('/suppliers', (Request request) async {
    request.require('suppliers.view');
    final rows = await inventory.suppliers(
      includeArchived: request.url.queryParameters['archived'] == 'true',
    );
    return jsonResponse({
      'suppliers': [for (final s in rows) supplierJson(s)],
    });
  });

  router.post('/suppliers', (Request request) async {
    request.require('suppliers.manage');
    final body = await readJsonBody(request);
    final saved = await inventory.upsertSupplier(
      SuppliersCompanion(
        id: _optional(body, 'id'),
        name: Value(_requiredString(body, 'name')),
        contactName: _optional(body, 'contactName'),
        phone: _optional(body, 'phone'),
        email: _optional(body, 'email'),
        address: _optional(body, 'address'),
        leadTimeDays: _optionalInt(body, 'leadTimeDays'),
        paymentTerms: _optional(body, 'paymentTerms'),
        notes: _optional(body, 'notes'),
        archived: _optionalBool(body, 'archived'),
      ),
    );
    return jsonResponse({'supplier': supplierJson(saved)});
  });

  router.get('/customers', (Request request) async {
    request.require('customers.view');
    final rows = await inventory.customers(
      includeArchived: request.url.queryParameters['archived'] == 'true',
    );
    return jsonResponse({
      'customers': [for (final c in rows) customerJson(c)],
    });
  });

  router.post('/customers', (Request request) async {
    request.require('customers.manage');
    final body = await readJsonBody(request);
    final saved = await inventory.upsertCustomer(
      CustomersCompanion(
        id: _optional(body, 'id'),
        name: Value(_requiredString(body, 'name')),
        contactName: _optional(body, 'contactName'),
        phone: _optional(body, 'phone'),
        email: _optional(body, 'email'),
        address: _optional(body, 'address'),
        priceTier: _optional(body, 'priceTier'),
        notes: _optional(body, 'notes'),
        archived: _optionalBool(body, 'archived'),
      ),
    );
    return jsonResponse({'customer': customerJson(saved)});
  });

  // ------------------------------------------------------------------
  // Categories, lookups, preferences — the workspace's, not the device's
  // ------------------------------------------------------------------
  router.get('/categories', (Request request) async {
    request.require('items.view');
    final rows = await inventory.categories();
    return jsonResponse({
      'categories': [for (final c in rows) categoryJson(c)],
    });
  });

  router.put('/categories', (Request request) async {
    request.require('categories.manage');
    final body = await readJsonBody(request);
    final raw = body['categories'];
    if (raw is! List) throw ApiError.badRequest('categories must be a list.');

    // NAME IS THE PRIMARY KEY, so the payload has to be a set before it
    // reaches the batch insert. It was taken at face value, and both ways that
    // can go wrong were reachable from the client: a blank name stored a
    // nameless category that then drew a blank row in the list, and a repeated
    // name failed the whole insert — a 500 that the app reported as "the
    // category could not be saved", for a payload that only ever names
    // categories the user already has. Renaming one category onto another's
    // name is how the repeat arises.
    //
    // First occurrence wins, so the position the client sent is kept.
    final seen = <String>{};
    final companions = <CategoriesCompanion>[];
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] case final Map entry) {
        final name = (entry['name'] as String? ?? '').trim();
        if (name.isEmpty || !seen.add(name)) continue;
        companions.add(
          CategoriesCompanion.insert(
            name: name,
            swatchIndex: (entry['swatchIndex'] as num?)?.toInt() ?? 0,
            position: Value(companions.length),
          ),
        );
      }
    }

    // Replaced wholesale because the client owns the order, and a per-row
    // update cannot express "this one moved above that one".
    await inventory.replaceCategories(companions);
    return jsonResponse({
      'categories': [
        for (final c in await inventory.categories()) categoryJson(c),
      ],
    });
  });

  router.get('/lookups', (Request request) async {
    request.require('items.view');
    final rows = await inventory.lookups(
      kind: request.url.queryParameters['kind'],
    );
    return jsonResponse({
      'lookups': [for (final l in rows) lookupJson(l)],
    });
  });

  router.put('/lookups/<kind>', (Request request, String kind) async {
    request.require('settings.manage');
    final body = await readJsonBody(request);
    final raw = body['values'];
    if (raw is! List) throw ApiError.badRequest('values must be a list.');

    await inventory.replaceLookups(kind, [
      for (var i = 0; i < raw.length; i++)
        LookupsCompanion.insert(
          kind: kind,
          value: raw[i].toString(),
          position: Value(i),
        ),
    ]);
    return jsonResponse({
      'lookups': [
        for (final l in await inventory.lookups(kind: kind)) lookupJson(l),
      ],
    });
  });

  // ------------------------------------------------------------------
  // Backup and restore
  // ------------------------------------------------------------------
  router.get('/backup', (Request request) async {
    request.require('backup.export');
    return jsonResponse(await inventory.exportEverything());
  });

  router.post('/restore', (Request request) async {
    request.require('backup.restore');
    final body = await readJsonBody(request);

    // Refused rather than guessed at. A restore replaces everything, so a
    // payload this cannot read must not be run half-understood.
    final version = (body['version'] as num?)?.toInt();
    if (version == null) {
      throw ApiError.badRequest(
        'This file is not a Stockpile backup: it carries no version.',
      );
    }
    if (version > InventoryService.backupVersion) {
      throw ApiError.badRequest(
        'This backup was taken by a newer version of Stockpile '
        '(format $version, this server reads up to '
        '${InventoryService.backupVersion}). Update the server first.',
      );
    }

    final raw = body['tables'];
    if (raw is! Map) {
      throw ApiError.badRequest('This backup has no tables in it.');
    }

    final tables = <String, List<Map<String, dynamic>>>{};
    for (final entry in raw.entries) {
      final rows = entry.value;
      if (rows is! List) continue;
      tables[entry.key.toString()] = [
        for (final row in rows)
          if (row is Map) row.cast<String, dynamic>(),
      ];
    }

    if (tables.values.every((rows) => rows.isEmpty)) {
      throw ApiError.badRequest(
        'That backup is empty. Restoring it would erase this workspace and '
        'put nothing back.',
      );
    }

    final Map<String, int> written;
    try {
      written = await inventory.restoreEverything(tables);
    } on ApiError {
      rethrow;
    } catch (error) {
      // A row the parser cannot read is a bad file, not a broken server, and
      // saying so is the difference between "try another backup" and "the
      // restore is broken". The transaction rolled back, so the workspace is
      // exactly as it was.
      throw ApiError.badRequest(
        'This backup could not be read, so nothing was changed. It may be '
        'from a different application, or the file may be damaged.',
      );
    }
    return jsonResponse({'restored': written});
  });

  router.get('/preferences', (Request request) async {
    request.require('items.view');
    return jsonResponse({'preferences': await inventory.preferences()});
  });

  router.patch('/preferences', (Request request) async {
    request.require('settings.manage');
    final body = await readJsonBody(request);
    final raw = body['preferences'];
    if (raw is! Map) {
      throw ApiError.badRequest('preferences must be an object.');
    }

    await inventory.writePreferences({
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    });
    return jsonResponse({'preferences': await inventory.preferences()});
  });

  return router;
}

// --------------------------------------------------------------------
// Body helpers
// --------------------------------------------------------------------

ItemsCompanion _itemCompanion(Map<String, Object?> body) => ItemsCompanion(
  id: _optional(body, 'id'),
  name: body.containsKey('name')
      ? Value(_requiredString(body, 'name'))
      : const Value.absent(),
  sku: _optional(body, 'sku'),
  barcode: _optional(body, 'barcode'),
  category: _optional(body, 'category'),
  location: _optional(body, 'location'),
  quantity: _optionalInt(body, 'quantity'),
  reorderLevel: _optionalInt(body, 'reorderLevel'),
  unit: _optional(body, 'unit'),
  unitCost: _optionalDouble(body, 'unitCost'),
  retailerPrice: _optionalDouble(body, 'retailerPrice'),
  distributorPrice: _optionalDouble(body, 'distributorPrice'),
  supplier: _optional(body, 'supplier'),
  supplierId: _optional(body, 'supplierId'),
  unitsPerPack: _optionalInt(body, 'unitsPerPack'),
  notes: _optional(body, 'notes'),
  photo: _optional(body, 'photo'),
);

/// Absent when the key was not sent, so a PATCH touches only what it names.
Value<T> _optional<T>(Map<String, Object?> body, String key) =>
    body.containsKey(key) ? Value(body[key] as T) : const Value.absent();

Value<int> _optionalInt(Map<String, Object?> body, String key) =>
    body.containsKey(key)
    ? Value((body[key] as num?)?.toInt() ?? 0)
    : const Value.absent();

Value<double> _optionalDouble(Map<String, Object?> body, String key) =>
    body.containsKey(key)
    ? Value((body[key] as num?)?.toDouble() ?? 0)
    : const Value.absent();

Value<bool> _optionalBool(Map<String, Object?> body, String key) =>
    body.containsKey(key) ? Value(body[key] == true) : const Value.absent();

String _requiredString(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value is! String || value.trim().isEmpty) {
    throw ApiError.badRequest('$key is required.');
  }
  return value.trim();
}

int _requiredInt(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value is! num) throw ApiError.badRequest('$key must be a number.');
  return value.toInt();
}

int _boundedInt(
  String? raw, {
  required int fallback,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}
