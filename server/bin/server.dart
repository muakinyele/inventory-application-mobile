import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as io;
import 'package:stockpile_server/src/api.dart';
import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';
import 'package:stockpile_server/src/email/mailer.dart';
import 'package:stockpile_server/src/email/smtp_mailer.dart';

Future<void> main(List<String> arguments) async {
  final Env env;
  try {
    env = Env.load();
  } on ConfigError catch (error) {
    // A misconfigured server refuses to start rather than run insecurely.
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 78; // EX_CONFIG
    return;
  }

  final db = AuthDatabase(
    openPostgres(env.databaseUrl, requireSsl: env.isProduction),
  );

  void logError(Object error, StackTrace stackTrace) {
    // Errors go to stderr only. They are never returned to a client, and the
    // message is never parsed into a response.
    stderr
      ..writeln('[${DateTime.now().toUtc().toIso8601String()}] $error')
      ..writeln(stackTrace);
  }

  await Bootstrap(db).run();

  final smtp = env.smtp;
  final Mailer mailer;
  if (smtp != null) {
    mailer = SmtpMailer(config: smtp, from: env.mailFrom);
  } else {
    // Development without SMTP: mail is recorded and its subject logged, but
    // never its links — those are secrets. The invite endpoint returns the
    // link directly when mail is disabled, which is how a local setup
    // completes the flow.
    mailer = InMemoryMailer(
      onSend: (message) => stdout.writeln(
        '[mail] to=${message.to} subject="${message.subject}"',
      ),
    );
    stdout.writeln(
      'EMAIL_HOST is not set — mail will be logged, not delivered.',
    );
  }

  final api = Api.build(env: env, db: db, mailer: mailer, onError: logError);

  // Housekeeping: expired sessions, spent tokens, and old login attempts.
  final sweeper = Timer.periodic(const Duration(hours: 6), (_) async {
    try {
      await api.sweep();
    } catch (error, stackTrace) {
      logError(error, stackTrace);
    }
  });

  final server = await io.serve(
    api.handler,
    InternetAddress.anyIPv4,
    env.port,
    poweredByHeader: null, // Says nothing about the stack.
  );
  server.autoCompress = true;

  stdout.writeln(
    'Stockpile identity API listening on http://${server.address.host}:'
    '${server.port} (${env.isProduction ? 'production' : 'development'})',
  );

  // Finish in-flight requests on SIGTERM rather than dropping them mid-write.
  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('Received $signal, shutting down.');
    sweeper.cancel();
    await server.close();
    await db.close();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(shutdown);
  ProcessSignal.sigint.watch().listen(shutdown);
}
