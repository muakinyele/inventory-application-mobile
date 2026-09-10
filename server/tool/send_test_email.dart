import 'dart:io';

import 'package:stockpile_server/src/config/env.dart';
import 'package:stockpile_server/src/email/mailer.dart';
import 'package:stockpile_server/src/email/smtp_mailer.dart';

/// Sends one message through the configured SMTP transport.
///
///     dart run tool/send_test_email.dart you@example.com
///
/// Exists so a deployment can prove its mail path works *before* someone
/// discovers it does not by failing to reset a password.
Future<void> main(List<String> arguments) async {
  final to = arguments.isEmpty ? null : arguments.first;
  if (to == null) {
    stderr.writeln('Usage: dart run tool/send_test_email.dart <address>');
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

  stdout.writeln(
    'Sending via ${smtp.host}:${smtp.port} '
    'as ${smtp.username ?? "(no username)"} -> $to',
  );

  try {
    await SmtpMailer(config: smtp, from: env.mailFrom).send(
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
