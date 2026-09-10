import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';

import '../config/env.dart';
import 'mailer.dart';

/// Delivers over SMTP, configured entirely from the environment (§15).
class SmtpMailer implements Mailer {
  SmtpMailer({required SmtpConfig config, required this.from})
    : _server = SmtpServer(
        config.host,
        port: config.port,
        username: config.username,
        password: config.password,
        ssl: config.useSsl,
        // STARTTLS is required unless explicitly waived, so credentials are
        // not sent in the clear by default. The waiver exists for a local
        // MailHog/Mailpit container, which speaks no TLS at all.
        ignoreBadCertificate: config.allowInsecure,
        allowInsecure: config.allowInsecure,
      );

  final SmtpServer _server;
  final String from;

  @override
  Future<void> send(EmailMessage message) async {
    final envelope = mailer.Message()
      ..from = _parseFrom(from)
      ..recipients.add(message.to)
      ..subject = message.subject
      ..text = message.text
      ..html = message.html;

    await mailer.send(envelope, _server);
  }

  /// Accepts either `no-reply@example.com` or `Name <no-reply@example.com>`.
  static mailer.Address _parseFrom(String value) {
    final match = RegExp(r'^\s*(.*?)\s*<([^>]+)>\s*$').firstMatch(value);
    if (match == null) return mailer.Address(value.trim());
    return mailer.Address(match.group(2)!.trim(), match.group(1));
  }
}
