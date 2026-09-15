import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stockpile/data/auth_api.dart';
import 'package:stockpile/data/database.dart';
import 'package:stockpile/data/inventory_api.dart';
import 'package:stockpile/data/inventory_repository.dart';
import 'package:stockpile/data/token_storage.dart';
import 'package:stockpile/models/item.dart';
import 'package:stockpile/state/inventory_controller.dart';

/// Stands in for the server. These assert what the controller does with the
/// answer, not what the server computes — that is covered on the other side.
class _Server {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];

  /// The count the fake currently believes. Changed between calls to stage a
  /// second device having moved it.
  int quantity = 10;

  bool conflictNext = false;
  bool failNext = false;

  http.Client client() => MockClient((request) async {
    final route = '${request.method} ${request.url.path}';
    calls.add(route);
    if (request.body.isNotEmpty) {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
    }

    if (failNext) {
      failNext = false;
      return http.Response('{}', 500);
    }

    if (route.endsWith('/stock/adjust')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (conflictNext) {
        conflictNext = false;
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'stock_conflict',
              'message': 'This item now reads $quantity, not '
                  '${body['expectedQuantity']}.',
            },
          }),
          409,
          headers: {'content-type': 'application/json'},
        );
      }
      quantity += (body['delta'] as num).toInt();
      return _ok({
        'item': _item(quantity: quantity),
        'movement': {
          'id': 'm1',
          'itemId': 'i1',
          'itemName': 'Widget',
          'kind': body['kind'],
          'before': (body['expectedQuantity'] as num).toInt(),
          'after': quantity,
          'note': body['note'],
          'actor': 'u1',
          'documentId': null,
          'at': '2026-09-15T10:00:00.000Z',
        },
      });
    }

    if (route.contains('/inventory/items/')) {
      return _ok({
        'item': _item(quantity: quantity),
        'stock': [
          {'itemId': 'i1', 'location': 'Main', 'quantity': quantity},
        ],
      });
    }

    return _ok({});
  });

  http.Response _ok(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  Map<String, dynamic> _item({required int quantity}) => {
    'id': 'i1',
    'name': 'Widget',
    'sku': '',
    'barcode': '',
    'category': '',
    'location': 'Main',
    'quantity': quantity,
    'reorderLevel': 0,
    'unit': 'pcs',
    'unitCost': 0,
    'retailerPrice': 0,
    'distributorPrice': 0,
    'supplier': '',
    'supplierId': null,
    'unitsPerPack': 1,
    'notes': '',
    'photo': null,
    'createdAt': '2026-09-01T10:00:00.000Z',
    'updatedAt': '2026-09-01T10:00:00.000Z',
  };
}

Future<InventoryController> _controller(_Server server) async {
  final storage = InMemoryTokenStorage();
  await storage.write(
    StoredTokens(
      accessToken: 'a',
      refreshToken: 'r',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    ),
  );
  final auth = AuthApi(
    baseUrl: 'https://example.test/api',
    storage: storage,
    client: server.client(),
  );
  await auth.restore();

  final repo = InventoryRepository(AppDatabase(NativeDatabase.memory()));
  final snapshot = Snapshot(
    items: [
      Item(
        id: 'i1',
        name: 'Widget',
        location: 'Main',
        quantity: 10,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    ],
    movements: const [],
    settings: (await repo.load()).settings,
  );
  return InventoryController(repo, snapshot, api: InventoryApi(auth));
}

void main() {
  test('a controller without an API keeps the on-device behaviour', () async {
    final repo = InventoryRepository(AppDatabase(NativeDatabase.memory()));
    final controller = InventoryController(repo, await repo.load());
    expect(controller.isShared, isFalse);
  });

  group('against a shared inventory', () {
    test('the server owns the arithmetic', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.adjustStock('i1', -3, note: 'Sold');

      // What this device believed, sent so the server can refuse if it moved.
      expect(server.bodies.single['expectedQuantity'], 10);
      expect(server.bodies.single['delta'], -3);
      // And the count that comes back is the server's, not one computed here.
      expect(controller.byId('i1')!.quantity, 7);
    });

    test('the movement the server recorded is the one shown', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.adjustStock('i1', -3, note: 'Sold');

      expect(controller.movements.first.before, 10);
      expect(controller.movements.first.after, 7);
      expect(controller.movements.first.note, 'Sold');
    });

    test('a stocktake sends the difference, not the total', () async {
      final server = _Server();
      final controller = await _controller(server);

      await controller.setStock('i1', 4);

      expect(server.bodies.single['delta'], -6);
      expect(server.bodies.single['expectedQuantity'], 10);
      expect(controller.byId('i1')!.quantity, 4);
    });

    test('a refused write leaves the server\'s count showing', () async {
      // Somebody else sold the last of it. Re-applying the user's change
      // blindly is the overwrite the refusal exists to prevent, so the screen
      // has to show what is actually there.
      final server = _Server()
        ..conflictNext = true
        ..quantity = 2;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -5);

      expect(controller.stockConflict, isNotNull);
      expect(controller.stockConflict, contains('now reads 2'));
      expect(controller.byId('i1')!.quantity, 2, reason: 're-read, not 5');
    });

    test('a later success clears the conflict', () async {
      final server = _Server()..conflictNext = true;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -1);
      expect(controller.stockConflict, isNotNull);

      await controller.adjustStock('i1', -1);
      expect(controller.stockConflict, isNull);
    });

    test('a transport failure is reported, not swallowed', () async {
      final server = _Server()..failNext = true;
      final controller = await _controller(server);

      await controller.adjustStock('i1', -1);

      expect(controller.lastWriteError, isNotNull);
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'nothing was applied locally',
      );
    });

    test('nothing is shown before the server has agreed to it', () async {
      // The on-device path updates the screen first and persists after, which
      // is right when this device is the only writer. Here a second device may
      // already have sold the last of it.
      final server = _Server();
      final controller = await _controller(server);

      final pending = controller.adjustStock('i1', -3);
      expect(
        controller.byId('i1')!.quantity,
        10,
        reason: 'still the old count while the request is in flight',
      );

      await pending;
      expect(controller.byId('i1')!.quantity, 7);
    });
  });
}
