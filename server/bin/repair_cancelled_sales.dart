import 'dart:io';

import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';
import 'package:stockpile_server/src/http/api_error.dart';
import 'package:stockpile_server/src/inventory/document_service.dart';
import 'package:stockpile_server/src/inventory/inventory_service.dart';

/// Finds, and optionally finishes, sales orders that were cancelled before
/// cancelling returned stock.
///
///     dart run bin/repair_cancelled_sales.dart           # report only
///     dart run bin/repair_cancelled_sales.dart --apply   # fix what it can
///
/// In a deployment:
///
///     docker compose run --rm --entrypoint /app/bin/repair_cancelled_sales \
///       api --apply
///
/// A sale is fixed by returning the stock it sent and cancelling its unpaid
/// invoices. One with money taken against it is reported and left alone:
/// refund it first. Running it twice changes nothing the second time.
Future<void> main(List<String> arguments) async {
  final apply = arguments.contains('--apply');
  if (arguments.any((a) => a != '--apply')) {
    stderr.writeln('Usage: repair_cancelled_sales [--apply]');
    exitCode = 64; // EX_USAGE
    return;
  }

  final Env env;
  try {
    env = Env.load();
  } on ConfigError catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 78; // EX_CONFIG
    return;
  }

  final db = AuthDatabase(
    openPostgres(env.databaseUrl, requireSsl: env.databaseRequiresSsl),
  );
  try {
    await Bootstrap(db).run();
    final documents = DocumentService(db, InventoryService(db));
    final issues = await documents.scanCancelledSales();

    if (issues.isEmpty) {
      stdout.writeln('No cancelled sales need repair.');
      return;
    }

    stdout.writeln(
      '${issues.length} cancelled ${issues.length == 1 ? 'sale needs' : 'sales need'} repair:\n',
    );
    for (final issue in issues) {
      final who = issue.customerName.isEmpty ? '' : ' (${issue.customerName})';
      stdout.writeln('${issue.salesOrderReference}$who');
      for (final out in issue.stockOut.values) {
        stdout.writeln('  stock out: ${out.quantity} x ${out.name}');
      }
      for (final invoice in issue.liveInvoices) {
        final paid = invoice.amountPaid > 0
            ? ', paid ${invoice.amountPaid.toStringAsFixed(2)}'
            : '';
        stdout.writeln('  live invoice: ${invoice.reference}$paid');
      }
      if (!issue.fixable) {
        stdout.writeln(
          '  BLOCKED: paid against (${issue.paidBy.join(', ')}). '
          'Refund first.',
        );
      }
    }

    if (!apply) {
      stdout.writeln('\nNothing changed. Run again with --apply to fix.');
      return;
    }

    stdout.writeln('');
    var fixed = 0;
    var blocked = 0;
    for (final issue in issues) {
      if (!issue.fixable) {
        blocked++;
        continue;
      }
      try {
        await documents.repairCancelledSale(
          id: issue.salesOrderId,
          actorId: 'repair_cancelled_sales',
        );
        fixed++;
        stdout.writeln('Fixed ${issue.salesOrderReference}');
      } on ApiError catch (error) {
        blocked++;
        stdout.writeln(
          'Could not fix ${issue.salesOrderReference}: ${error.message}',
        );
      }
    }
    stdout.writeln('\nFixed $fixed, left $blocked.');
    if (blocked > 0) exitCode = 2;
  } finally {
    await db.close();
  }
}
