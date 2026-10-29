import 'dart:io';

import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';
import 'package:stockpile_server/src/inventory/inventory_service.dart';

/// Finds, and optionally corrects, items an old bug drove below zero.
///
///     dart run bin/repair_stock.dart           # report only
///     dart run bin/repair_stock.dart --apply   # correct them
///
/// In a deployment:
///
///     docker compose run --rm --entrypoint /app/bin/repair_stock api --apply
///
/// Items restored from a backup carried a total and no per-location stock, so
/// the first sale passed the stock check against the total and was then taken
/// from empty locations: a count of 5 sold for 5 read -5. Each item's own
/// movements record what was meant, so the count is rebuilt from them, and
/// the correction is recorded as an adjustment. Running it twice changes
/// nothing the second time.
Future<void> main(List<String> arguments) async {
  final apply = arguments.contains('--apply');
  if (arguments.any((a) => a != '--apply')) {
    stderr.writeln('Usage: repair_stock [--apply]');
    exitCode = 64;
    return;
  }

  final Env env;
  try {
    env = Env.load();
  } on ConfigError catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 78;
    return;
  }

  final db = AuthDatabase(
    openPostgres(env.databaseUrl, requireSsl: env.databaseRequiresSsl),
  );
  try {
    // Also lines every item's locations up with its total.
    await Bootstrap(db).run();
    final inventory = InventoryService(db);
    final damaged = await inventory.scanStockDamage();

    if (damaged.isEmpty) {
      stdout.writeln('No item has stock below zero. Nothing to correct.');
      return;
    }

    stdout.writeln('${damaged.length} item(s) to correct:\n');
    for (final d in damaged) {
      final where = d.locations.entries
          .map((e) => '${e.key} ${e.value}')
          .join(', ');
      stdout.writeln(
        '  ${d.name}: reads ${d.current}, should be ${d.intended}  ($where)',
      );
    }

    if (!apply) {
      stdout.writeln('\nNothing changed. Run again with --apply to correct.');
      return;
    }

    for (final d in damaged) {
      await inventory.repairStockDamage(
        itemId: d.itemId,
        actorId: 'repair_stock',
      );
    }
    stdout.writeln('\nCorrected ${damaged.length}.');
  } finally {
    await db.close();
  }
}
