/// One outgoing message.
class EmailMessage {
  const EmailMessage({
    required this.to,
    required this.subject,
    required this.html,
    required this.text,
  });

  final String to;
  final String subject;
  final String html;

  /// Always sent alongside the HTML. Some mail clients — and most security
  /// teams' quarantine views — only ever show this part.
  final String text;
}

/// How mail leaves the system.
///
/// An interface rather than a direct SMTP call so the provider is one
/// constructor argument (§15): swapping SMTP for a transactional API later
/// touches this file and `bin/server.dart`, nothing else. It also gives tests
/// somewhere to capture mail without a network.
abstract class Mailer {
  Future<void> send(EmailMessage message);
}

/// Development and test sender: records mail and logs a one-line summary.
///
/// Deliberately logs the *subject and recipient only*. Reset and invitation
/// links are secrets, and a log file is the wrong place for them — so during
/// development they are read from [sent], not from the console.
class InMemoryMailer implements Mailer {
  InMemoryMailer({this.onSend});

  final void Function(EmailMessage message)? onSend;
  final List<EmailMessage> sent = [];

  @override
  Future<void> send(EmailMessage message) async {
    sent.add(message);
    onSend?.call(message);
  }

  EmailMessage? lastTo(String address) {
    final lower = address.toLowerCase();
    for (var i = sent.length - 1; i >= 0; i--) {
      if (sent[i].to.toLowerCase() == lower) return sent[i];
    }
    return null;
  }

  void clear() => sent.clear();
}

/// Wraps another mailer so a delivery failure can never break the request that
/// triggered it.
///
/// Password reset must return the same generic response whether or not the
/// address exists — and whether or not the SMTP host happened to be up.
/// Letting an SMTP timeout surface as a 500 would turn mail-server health into
/// an account-enumeration oracle.
class FailSafeMailer implements Mailer {
  FailSafeMailer(this._inner, {required this.onError});

  final Mailer _inner;
  final void Function(Object error, StackTrace stackTrace) onError;

  @override
  Future<void> send(EmailMessage message) async {
    try {
      await _inner.send(message);
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }
}
