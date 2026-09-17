import 'dart:io';

import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/email/mailer.dart';
import 'package:stockpile_server/src/email/smtp_mailer.dart';

/// Sends one message through the configured SMTP transport.
///
///     dart run tool/send_test_email.dart you@example.com
///
/// and, on a deployment, as /app/bin/send_test_email — which is the only place
/// it is any use, since the mail path only ever fails there. It is built into
/// the image for that reason despite living in tool/ rather than bin/.
///
/// Exists so a deployment can prove its mail path works *before* someone
/// discovers it does not by failing to reset a password.
Future<void> main(List<String> arguments) async {
  final to = arguments.isEmpty ? null : arguments.first;
  if (to == null) {
    stderr.writeln(
      'Usage: send_test_email <address>\n'
      '\n'
      'Locally:   dart run tool/send_test_email.dart you@example.com\n'
      'Deployed:  docker compose -f docker-compose.prod.yml run --rm \\\n'
      '             --entrypoint /app/bin/send_test_email api you@example.com',
    );
    exitCode = 64;
    return;
  }

  final env = Env.load();
  final smtp = env.smtp;
  if (smtp == null) {
    stderr.writeln('EMAIL_HOST is not set; nothing to test.');
    exitCode = 78;
    return;
  }

  // The From address is printed because it is the field most likely to be
  // wrong and least likely to be noticed: the username authenticates, but
  // the From is what the message claims to be, and an unroutable one is
  // rejected as an invalid message with nothing to say why.
  stdout.writeln(
    'Sending via ${smtp.host}:${smtp.port}\n'
    '  authenticating as ${smtp.username ?? "(no username)"}\n'
    '  from ${env.mailFrom}\n'
    '  to   $to',
  );

  try {
    // No database here, so no workspace name to resolve — this proves the
    // transport, not the display name.
    await SmtpMailer(config: smtp, from: () async => env.mailFrom).send(
      EmailMessage(
        to: to,
        subject: '${env.appName}: mail is configured correctly',
        html:
            '<p>If you are reading this, ${env.appName} can send mail.</p>'
            '<p>Password resets, invitations and security notices will '
            'reach you.</p>',
        text:
            'If you are reading this, ${env.appName} can send mail.\n'
            'Password resets, invitations and security notices will reach '
            'you.\n',
      ),
    );
    stdout.writeln('Delivered.');
  } catch (error) {
    // Printed rather than swallowed: this tool exists to surface exactly this.
    stderr.writeln('FAILED: $error');
    exitCode = 1;
  }
}
