import 'dart:io';

import 'package:stockpile_server/src/auth/token_store.dart';
import 'package:stockpile_server/src/auth/tokens.dart';
import 'package:stockpile_server/src/bootstrap.dart';
import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/db/database.dart';
import 'package:stockpile_server/src/email/mailer.dart';
import 'package:stockpile_server/src/email/mail_identity.dart';
import 'package:stockpile_server/src/email/smtp_mailer.dart';
import 'package:stockpile_server/src/email/templates.dart';
import 'package:stockpile_server/src/users/user_service.dart';

/// Creates the first administrator (§30).
///
///     dart run bin/create_admin.dart --email you@example.com --name "Your Name"
///
/// The account is created *pending, with no password*, and is claimed through
/// the ordinary invitation link. No password is ever typed on a command line
/// or left in a shell history file.
Future<void> main(List<String> arguments) async {
  final options = _parse(arguments);
  final email = options['email'];
  final name = options['name'];

  if (email == null || name == null) {
    stderr.writeln(
      'Usage: dart run bin/create_admin.dart '
      '--email <address> --name "<full name>"',
    );
    exitCode = 64; // EX_USAGE
    return;
  }
  if (!isPlausibleEmail(email.toLowerCase())) {
    stderr.writeln('"$email" does not look like an email address.');
    exitCode = 65; // EX_DATAERR
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
  final bootstrap = Bootstrap(db);
  await bootstrap.run();

  final force = options.containsKey('force');
  if (!await bootstrap.needsFirstAdministrator() && !force) {
    stderr.writeln(
      'An administrator already exists. Invite further users from the app, or '
      'pass --force if you are certain you need another bootstrap account.',
    );
    await db.close();
    exitCode = 1;
    return;
  }

  final tokenStore = TokenStore(db: db, tokens: TokenService(env.tokenPepper));
  final created = await bootstrap.createFirstAdministrator(
    email: email,
    name: name,
    tokenStore: tokenStore,
    validFor: env.invitationTtl,
  );

  final url = '${env.appUrl}/#/accept-invitation?token=${created.token}';
  final smtp = env.smtp;

  if (smtp != null) {
    final templates = EmailTemplates(appName: env.appName, appUrl: env.appUrl);
    final identity = MailIdentity(db: db, env: env);
    final mailer = SmtpMailer(config: smtp, from: identity.resolve);
    await FailSafeMailer(
      mailer,
      onError: (error, _) => stderr.writeln('Could not send mail: $error'),
    ).send(
      templates.invitation(
        to: email.toLowerCase(),
        name: name,
        invitedBy: 'The setup process',
        roleName: 'Administrator',
        acceptUrl: url,
        validFor: env.invitationTtl,
      ),
    );
    stdout.writeln('Invitation sent to $email.');
  }

  // Printed to the operator's terminal, which is the one place this secret is
  // acceptable: they are the person who just asked for it, and without SMTP
  // there is no other way to claim the account.
  stdout
    ..writeln('Administrator created: $email')
    ..writeln('Claim it within ${env.invitationTtl.inHours} hours at:')
    ..writeln(url);

  await db.close();
}

Map<String, String?> _parse(List<String> arguments) {
  final result = <String, String?>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) continue;
    final key = argument.substring(2);
    final next = i + 1 < arguments.length ? arguments[i + 1] : null;
    if (next == null || next.startsWith('--')) {
      result[key] = null;
      if (key == 'force') result[key] = 'true';
    } else {
      result[key] = next;
      i++;
    }
  }
  return result;
}
