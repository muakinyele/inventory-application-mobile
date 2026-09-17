import '../config/env.dart';
import '../db/database.dart';

/// Works out who mail should appear to come from.
///
/// The address is settled by configuration — it has to be one the SMTP account
/// is allowed to send as — but the *name* beside it belongs to the workspace.
/// A supplier receiving an invitation should see the company that sent it, not
/// the name of the software it was sent with.
///
/// Resolved per send rather than at startup, because the workspace name is
/// editable and the alternative is mail going out under the old one until
/// somebody restarts the server.
class MailIdentity {
  MailIdentity({required this.db, required this.env});

  final AuthDatabase db;
  final Env env;

  /// Preferences are one small row and mail is not a hot path, but a rename is
  /// rare and a failed lookup must not stop a password reset — so a miss falls
  /// back rather than throwing.
  Future<String> resolve() async {
    final configured = env.mailFrom.trim();

    // An explicit `Name <address>` is somebody stating exactly what they want.
    if (_hasDisplayName(configured)) return configured;

    // EMAIL_FROM is typed by a person, and "who mail comes from" reads like a
    // name — so a value with no `@` in it is one, not an address. Using it as
    // the address is how this failed before: the mailer rejects the envelope
    // as an invalid message, which says nothing about which field was wrong.
    final configuredIsName = configured.isNotEmpty && !configured.contains('@');

    final address = configuredIsName
        ? (env.smtp?.username ?? configured)
        : _addressOf(configured);

    final name = configuredIsName
        ? configured
        : (await _workspaceName() ?? env.appName);

    if (!address.contains('@')) {
      // Nothing usable anywhere. Returning the address alone at least fails
      // against the mail server, where the error names a real cause.
      return address;
    }
    return name.isEmpty ? address : '$name <$address>';
  }

  Future<String?> _workspaceName() async {
    try {
      final row = await (db.select(
        db.preferences,
      )..where((t) => t.key.equals('companyName'))).getSingleOrNull();
      final value = row?.value.trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      // Mail matters more than the name on it.
      return null;
    }
  }

  static bool _hasDisplayName(String value) =>
      RegExp(r'^\s*\S.*<[^>]+>\s*$').hasMatch(value);

  static String _addressOf(String value) {
    final match = RegExp(r'<([^>]+)>').firstMatch(value);
    return (match?.group(1) ?? value).trim();
  }
}
