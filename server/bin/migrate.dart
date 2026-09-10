import 'dart:io';

import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';

/// Brings the database up to date, then exits.
///
///     dart run bin/migrate.dart
///
/// The server does this for itself on boot, so this exists for the deploy
/// pipeline rather than for the app: it lets migrations run **once**, as their
/// own step, before any new container starts serving. Two replicas racing to
/// create the same table is the failure this avoids.
///
/// Safe to run repeatedly. Drift applies only the migrations the database has
/// not seen, and the permission and role sync is an upsert.
Future<void> main(List<String> arguments) async {
  final Env env;
  try {
    env = Env.load();
  } on ConfigError catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 78; // EX_CONFIG
    return;
  }

  // A container starting alongside its database will lose that race the first
  // time, every time. Compose health-gates this too, but the retry means the
  // tool is also correct when run against a database that is merely slow.
  final db = await _connectWithRetry(env);
  if (db == null) {
    stderr.writeln('Could not reach the database. Giving up.');
    exitCode = 75; // EX_TEMPFAIL — a retry might well succeed
    return;
  }

  try {
    stdout.writeln('Applying migrations…');
    await Bootstrap(db).run();

    final permissions = await db
        .customSelect('select count(*) as n from permissions')
        .getSingle();
    final roles = await db
        .customSelect('select count(*) as n from roles')
        .getSingle();

    stdout
      ..writeln('Schema is up to date.')
      ..writeln('  permissions: ${permissions.data['n']}')
      ..writeln('  roles:       ${roles.data['n']}');

    if (await Bootstrap(db).needsFirstAdministrator()) {
      // Stated rather than silently fine: a fresh deployment with no
      // administrator cannot be signed in to, and the operator needs to know
      // to run create_admin before anyone tries.
      stdout.writeln(
        '\nNo administrator exists yet. Create one with:\n'
        '  docker compose run --rm api /app/bin/create_admin '
        '--email you@example.com --name "Your Name"',
      );
    }
  } finally {
    await db.close();
  }
}

/// Retries the first connection with a linear backoff.
Future<AuthDatabase?> _connectWithRetry(
  Env env, {
  int attempts = 30,
  Duration gap = const Duration(seconds: 2),
}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    final db = AuthDatabase(
      openPostgres(env.databaseUrl, requireSsl: env.databaseRequiresSsl),
    );
    try {
      // Any statement forces the connection to actually open; constructing
      // the database object alone proves nothing.
      await db.customSelect('select 1').get();
      return db;
    } catch (error) {
      await db.close();
      if (attempt == attempts) {
        stderr.writeln('Database unreachable after $attempts attempts: $error');
        return null;
      }
      stdout.writeln('Waiting for the database… ($attempt/$attempts)');
      await Future<void>.delayed(gap);
    }
  }
  return null;
}
