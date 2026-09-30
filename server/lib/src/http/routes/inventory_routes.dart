import 'package:drift/drift.dart' show Value;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../db/database.dart';
import '../../audit/audit_actions.dart';
import '../../audit/audit_service.dart';
import '../../inventory/inventory_service.dart';
import '../api_error.dart';
import '../image_payload.dart';
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
Router inventoryRoutes({
  required InventoryService inventory,
  required AuditService audit,
}) {
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
    final caller = request.require('settings.manage');

    // Counted BEFORE, because afterwards there is nothing left to count and
    // "how much was lost" is the first question anybody asks.
    final before = await inventory.rowCounts();
    await inventory.eraseEverything();

    await audit.record(
      action: AuditAction.inventoryErased,
      actorId: caller.user.id,
      actorEmail: caller.user.email,
      targetType: 'inventory',
      ipAddress: request.clientIp,
      metadata: before,
    );
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
    final caller = request.require('backup.export');
    final payload = await inventory.exportEverything();

    // THE ONE THAT MOST NEEDED RECORDING. A backup is every customer's name,
    // phone number and email address, every supplier, and the whole trading
    // history, in one file. Taking it is silent — no screen changes, nothing
    // breaks — so without this a leaver could copy the business on their last
    // afternoon and nobody would ever have a reason to look.
    final tables = payload['tables'];
    await audit.record(
      action: AuditAction.inventoryExported,
      actorId: caller.user.id,
      actorEmail: caller.user.email,
      targetType: 'inventory',
      ipAddress: request.clientIp,
      metadata: {
        if (tables is Map)
          for (final entry in tables.entries)
            if (entry.value is List && (entry.value as List).isNotEmpty)
              entry.key.toString(): (entry.value as List).length,
      },
    );

    return jsonResponse(payload);
  });

  router.post('/restore', (Request request) async {
    final caller = request.require('backup.restore');
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

    // A BACKUP THE APP ITSELF WROTE LAST MONTH IS STILL A BACKUP. Before the
    // server took this over, the settings screen assembled one in the browser
    // — `{version, items, movements, receipts, settings}`, with dates as ISO
    // strings and a receipt carrying its lines inside it. Every file anybody
    // already has is that shape, and a restore that only reads the new one
    // tells them their backup is empty. It is not; it is just older.
    final raw = body['tables'] ?? _tablesFromLegacyBackup(body);
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
    await audit.record(
      action: AuditAction.inventoryRestored,
      actorId: caller.user.id,
      actorEmail: caller.user.email,
      targetType: 'inventory',
      ipAddress: request.clientIp,
      metadata: {'replacedWith': written, 'backupVersion': version},
    );

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
        entry.key.toString(): entry.key == 'companyLogo'
            // The logo is the other image this app stores, and it reaches the
            // database through this untyped bag rather than a column of its
            // own — so it would otherwise never be looked at.
            ? validatedImage(entry.value, field: 'companyLogo')
            : entry.value?.toString() ?? '',
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
  // Checked rather than taken on trust: this column is decoded straight into
  // an image widget and embedded into PDFs, and nothing else ever looks at it.
  photo: body.containsKey('photo')
      ? Value(validatedImage(body['photo'], field: 'photo'))
      : const Value.absent(),
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

/// Converts the old browser-assembled backup into the table shape.
///
/// Returns null when the body is not one, so the caller can report "no tables"
/// rather than a confusing conversion error.
///
/// Only four collections were ever in that format — items, movements,
/// receipts and settings — so a legacy restore cannot bring back suppliers,
/// customers or purchase and sales orders. They were not in the file. What is
/// there comes back exactly.
Map<String, Object?>? _tablesFromLegacyBackup(Map<String, Object?> body) {
  final items = body['items'];
  final movements = body['movements'];
  final receipts = body['receipts'];
  final settings = body['settings'];

  final looksLegacy =
      items is List || movements is List || receipts is List || settings is Map;
  if (!looksLegacy) return null;

  // Dates were ISO strings then and are epoch milliseconds now, which is what
  // drift's own serialiser reads. A row whose date will not parse is kept with
  // the epoch rather than dropped: a movement with a broken timestamp is still
  // a movement that happened.
  Object? when(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) {
      return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  Map<String, Object?> dated(Map row, List<String> fields) => {
    for (final entry in row.entries)
      if (entry.value is! List && entry.value is! Map)
        entry.key.toString(): fields.contains(entry.key)
            ? when(entry.value)
            : entry.value,
  };

  final itemRows = [
    for (final row in _list(items))
      dated(row, const ['createdAt', 'updatedAt']),
  ];

  final movementRows = [
    for (final row in _list(movements)) dated(row, const ['at']),
  ];

  // A receipt carried its lines inside it; the tables keep them apart, and a
  // line needs the receipt id the nesting used to imply.
  final receiptRows = <Map<String, Object?>>[];
  final receiptLineRows = <Map<String, Object?>>[];
  for (final row in _list(receipts)) {
    final id = row['id'] as String? ?? '';
    receiptRows.add(
      dated(row, const [
        'issuedAt',
        'refundedAt',
        'voidedAt',
        'createdAt',
        'updatedAt',
      ]),
    );
    final lines = row['lines'];
    if (lines is! List) continue;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] case final Map line) {
        receiptLineRows.add({
          for (final entry in line.entries)
            if (entry.value is! List && entry.value is! Map)
              entry.key.toString(): entry.value,
          'receiptId': id,
          'position': i,
        });
      }
    }
  }

  // Settings were one object; they are three tables now.
  final categoryRows = <Map<String, Object?>>[];
  final lookupRows = <Map<String, Object?>>[];
  final preferenceRows = <Map<String, Object?>>[];

  if (settings is Map) {
    final colours = settings['categoryColors'];
    final swatches = colours is Map
        ? {
            for (final entry in colours.entries)
              entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
          }
        : const <String, int>{};

    var position = 0;
    for (final name in _list(settings['categories'], strings: true)) {
      final text = name['value'] as String;
      if (text.trim().isEmpty) continue;
      categoryRows.add({
        'name': text,
        'swatchIndex': swatches[text] ?? 0,
        'position': position++,
      });
    }

    for (final kind in const ['locations', 'units']) {
      var i = 0;
      for (final value in _list(settings[kind], strings: true)) {
        final text = value['value'] as String;
        if (text.trim().isEmpty) continue;
        lookupRows.add({
          // The tables use the singular, the settings object the plural.
          'kind': kind.substring(0, kind.length - 1),
          'value': text,
          'position': i++,
        });
      }
    }

    // The scalars, minus the three that became tables of their own and the
    // theme, which is a per-device choice rather than the workspace's.
    const skip = {
      'categories',
      'locations',
      'units',
      'categoryColors',
      'themeMode',
    };
    for (final entry in settings.entries) {
      final key = entry.key.toString();
      if (skip.contains(key)) continue;
      final value = entry.value;
      if (value is List || value is Map) continue;
      preferenceRows.add({'key': key, 'value': '${value ?? ''}'});
    }
  }

  return {
    'items': itemRows,
    'movements': movementRows,
    'receipts': receiptRows,
    'receiptLines': receiptLineRows,
    'categories': categoryRows,
    'lookups': lookupRows,
    'preferences': preferenceRows,
  };
}

/// The maps in [raw], or single-value maps for a list of plain strings.
List<Map<String, Object?>> _list(Object? raw, {bool strings = false}) {
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map)
        entry.cast<String, Object?>()
      else if (strings && entry is String)
        {'value': entry},
  ];
}
