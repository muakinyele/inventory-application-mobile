import 'mailer.dart';

/// Builds every message the system sends (§13).
///
/// One class rather than scattered string literals, so the wording, the
/// footer and the security advice stay consistent — and so a template can be
/// asserted in a test without standing up SMTP.
///
/// Two rules hold across all of them:
///  * A link is never the only affordance — the URL is always shown as text
///    too, because plenty of corporate mail clients strip anchors.
///  * No message contains a password, a token, or anything about *why* an
///    address was or was not found in the system.
class EmailTemplates {
  EmailTemplates({required this.appName, required this.appUrl});

  final String appName;
  final String appUrl;

  EmailMessage invitation({
    required String to,
    required String name,
    required String invitedBy,
    required String roleName,
    required String acceptUrl,
    required Duration validFor,
  }) {
    final expiry = _humanDuration(validFor);
    return _build(
      to: to,
      subject: 'You have been invited to $appName',
      heading: 'Welcome to $appName',
      greeting: 'Hi $name,',
      paragraphs: [
        '${_escape(invitedBy)} has invited you to join ${_escape(appName)} '
            'as <strong>${_escape(roleName)}</strong>.',
        'Set a password to activate your account. This invitation expires in '
            '$expiry.',
      ],
      action: _Action('Set your password', acceptUrl),
      footer:
          'If you were not expecting this invitation you can ignore this '
          'message and no account will be activated.',
    );
  }

  EmailMessage verifyEmail({
    required String to,
    required String name,
    required String verifyUrl,
    required Duration validFor,
  }) {
    return _build(
      to: to,
      subject: 'Confirm your email address',
      heading: 'Confirm your email address',
      greeting: 'Hi $name,',
      paragraphs: [
        'Confirm this address so you can receive security notifications about '
            'your ${_escape(appName)} account.',
        'This link expires in ${_humanDuration(validFor)}.',
      ],
      action: _Action('Confirm email address', verifyUrl),
      footer:
          'If you did not create this account, you can safely ignore this '
          'message.',
    );
  }

  EmailMessage emailChange({
    required String to,
    required String name,
    required String verifyUrl,
    required Duration validFor,
  }) {
    return _build(
      to: to,
      subject: 'Confirm your new email address',
      heading: 'Confirm your new email address',
      greeting: 'Hi $name,',
      paragraphs: [
        'You asked to change the email address on your ${_escape(appName)} account to '
            'this one. Confirm it to finish the change.',
        'Until you do, your account keeps its current address. This link '
            'expires in ${_humanDuration(validFor)}.',
      ],
      action: _Action('Confirm new address', verifyUrl),
      footer:
          'If you did not request this change, ignore this message and tell '
          'your administrator.',
    );
  }

  EmailMessage passwordReset({
    required String to,
    required String name,
    required String resetUrl,
    required Duration validFor,
  }) {
    return _build(
      to: to,
      subject: 'Reset your ${_escape(appName)} password',
      heading: 'Reset your password',
      greeting: 'Hi $name,',
      paragraphs: [
        'We received a request to reset the password on your ${_escape(appName)} '
            'account.',
        'This link can be used once and expires in '
            '${_humanDuration(validFor)}.',
      ],
      action: _Action('Choose a new password', resetUrl),
      footer:
          'If you did not request a password reset, no action is needed — your '
          'password has not changed. If you keep receiving these, tell your '
          'administrator.',
    );
  }

  EmailMessage passwordChanged({
    required String to,
    required String name,
    required DateTime when,
    required String? ipAddress,
    required bool otherSessionsRevoked,
  }) {
    return _build(
      to: to,
      subject: 'Your $appName password was changed',
      heading: 'Your password was changed',
      greeting: 'Hi $name,',
      paragraphs: [
        'The password on your ${_escape(appName)} account was changed on '
            '${_formatTime(when)}${_escape(_fromIp(ipAddress))}.',
        if (otherSessionsRevoked)
          'For your security, every other signed-in device has been signed '
              'out.',
      ],
      footer:
          'If this was not you, your account may be compromised. Contact your '
          'administrator immediately.',
    );
  }

  EmailMessage newLogin({
    required String to,
    required String name,
    required DateTime when,
    required String deviceLabel,
    required String? ipAddress,
    required String securityUrl,
  }) {
    return _build(
      to: to,
      subject: 'New sign-in to your ${_escape(appName)} account',
      heading: 'New sign-in',
      greeting: 'Hi $name,',
      paragraphs: [
        'Your ${_escape(appName)} account was signed in to from a new '
            'device on '
            '${_formatTime(when)}.',
        'Device: <strong>${_escape(deviceLabel)}</strong>'
            '${_escape(_fromIp(ipAddress))}.',
      ],
      action: _Action('Review your active sessions', securityUrl),
      footer:
          'If this was you, nothing to do. If not, change your password and '
          'sign out the other devices from your security settings.',
    );
  }

  /// Sent to the *old* address after a change completes.
  ///
  /// The one channel that still reaches the original owner if the change was
  /// not theirs, so it names the new address and says what to do about it.
  EmailMessage emailChanged({
    required String to,
    required String name,
    required String newEmail,
  }) {
    return _build(
      to: to,
      subject: 'The email address on your ${_escape(appName)} account changed',
      heading: 'Your email address was changed',
      greeting: 'Hi $name,',
      paragraphs: [
        'The email address on your ${_escape(appName)} account was changed to '
            '<strong>${_escape(newEmail)}</strong>.',
        'This message is going to your previous address so you know it '
            'happened. Sign-in notifications will now go to the new address.',
      ],
      footer:
          'If you did not make this change, contact your administrator '
          'immediately — someone else may have access to your account.',
    );
  }

  EmailMessage accountDisabled({required String to, required String name}) {
    return _build(
      to: to,
      subject: 'Your $appName account has been disabled',
      heading: 'Your account has been disabled',
      greeting: 'Hi $name,',
      paragraphs: [
        'An administrator has disabled your ${_escape(appName)} account. You will not be '
            'able to sign in until it is restored.',
        'Your data has not been deleted.',
      ],
      footer: 'If you believe this is a mistake, contact your administrator.',
    );
  }

  EmailMessage accountEnabled({required String to, required String name}) {
    return _build(
      to: to,
      subject: 'Your $appName account has been restored',
      heading: 'Your account has been restored',
      greeting: 'Hi $name,',
      paragraphs: ['You can sign in to ${_escape(appName)} again.'],
      action: _Action('Sign in', '$appUrl/#/login'),
      footer: 'If you did not expect this, contact your administrator.',
    );
  }

  EmailMessage accountLocked({
    required String to,
    required String name,
    required Duration lockedFor,
  }) {
    return _build(
      to: to,
      subject: 'Too many sign-in attempts on your ${_escape(appName)} account',
      heading: 'Your account is temporarily locked',
      greeting: 'Hi $name,',
      paragraphs: [
        'There have been several failed sign-in attempts on your account, so '
            'it has been locked for ${_humanDuration(lockedFor)}.',
        'It will unlock by itself. You can also reset your password to regain '
            'access straight away.',
      ],
      action: _Action('Reset your password', '$appUrl/#/forgot-password'),
      footer:
          'If this was not you, someone may be trying to guess your password. '
          'Reset it and tell your administrator.',
    );
  }

  EmailMessage passwordResetByAdmin({
    required String to,
    required String name,
    required String adminName,
    required String resetUrl,
    required Duration validFor,
  }) {
    return _build(
      to: to,
      subject:
          'A password reset was started for your ${_escape(appName)} account',
      heading: 'Set a new password',
      greeting: 'Hi $name,',
      paragraphs: [
        '${_escape(adminName)} started a password reset for your '
            '${_escape(appName)} account.',
        'Every device signed in to your account has been signed out. Choose a '
            'new password to get back in. This link expires in '
            '${_humanDuration(validFor)}.',
      ],
      action: _Action('Choose a new password', resetUrl),
      footer: 'If you were not expecting this, contact your administrator.',
    );
  }

  // ---------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------

  /// Inline styles and a table-free single column: the lowest common
  /// denominator that renders the same in Outlook, Gmail and Apple Mail.
  /// Colours match the app's palette so the mail looks like the product.
  EmailMessage _build({
    required String to,
    required String subject,
    required String heading,
    required String greeting,
    required List<String> paragraphs,
    _Action? action,
    required String footer,
  }) {
    final body = StringBuffer()
      ..writeln(
        '<div style="margin:0;padding:24px;background:#f9f9f7;'
        'font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,'
        'Helvetica,Arial,sans-serif;">',
      )
      ..writeln(
        '<div style="max-width:520px;margin:0 auto;background:#ffffff;'
        'border:1px solid #e5e5e0;border-radius:12px;padding:32px;">',
      )
      ..writeln(
        '<div style="font-size:13px;font-weight:600;color:#2a78d6;'
        'letter-spacing:0.04em;text-transform:uppercase;">'
        '${_escape(appName)}</div>',
      )
      ..writeln(
        '<h1 style="margin:12px 0 20px;font-size:22px;line-height:1.3;'
        'color:#1a1a17;font-weight:700;">${_escape(heading)}</h1>',
      )
      ..writeln(
        '<p style="margin:0 0 16px;font-size:15px;line-height:1.6;'
        'color:#3d3d38;">${_escape(greeting)}</p>',
      );

    for (final paragraph in paragraphs) {
      body.writeln(
        '<p style="margin:0 0 16px;font-size:15px;line-height:1.6;'
        'color:#3d3d38;">$paragraph</p>',
      );
    }

    if (action != null) {
      body
        ..writeln(
          '<p style="margin:24px 0;">'
          '<a href="${_escapeAttribute(action.url)}" '
          'style="display:inline-block;background:#2a78d6;color:#ffffff;'
          'text-decoration:none;padding:12px 22px;border-radius:8px;'
          'font-size:15px;font-weight:600;">${_escape(action.label)}</a></p>',
        )
        // Shown as text as well, because a stripped anchor would otherwise
        // leave the recipient with no way through.
        ..writeln(
          '<p style="margin:0 0 16px;font-size:13px;line-height:1.6;'
          'color:#6b6b63;">Or paste this into your browser:<br>'
          '<span style="color:#2a78d6;word-break:break-all;">'
          '${_escape(action.url)}</span></p>',
        );
    }

    body
      ..writeln(
        '<hr style="border:none;border-top:1px solid #e5e5e0;'
        'margin:24px 0;">',
      )
      ..writeln(
        '<p style="margin:0;font-size:13px;line-height:1.6;'
        'color:#6b6b63;">${_escape(footer)}</p>',
      )
      ..writeln('</div>')
      ..writeln(
        '<p style="max-width:520px;margin:16px auto 0;font-size:12px;'
        'color:#8a8a80;text-align:center;">'
        'This is an automated message from ${_escape(appName)}. '
        'Please do not reply.</p>',
      )
      ..writeln('</div>');

    final plain = StringBuffer()
      ..writeln(heading)
      ..writeln('=' * heading.length)
      ..writeln()
      ..writeln(greeting)
      ..writeln();
    for (final paragraph in paragraphs) {
      plain
        ..writeln(_stripTags(paragraph))
        ..writeln();
    }
    if (action != null) {
      plain
        ..writeln('${action.label}: ${action.url}')
        ..writeln();
    }
    plain
      ..writeln('--')
      ..writeln(footer)
      ..writeln(
        'This is an automated message from $appName. '
        'Please do not reply.',
      );

    return EmailMessage(
      to: to,
      subject: subject,
      html: body.toString(),
      text: plain.toString(),
    );
  }

  static String _fromIp(String? ip) => ip == null ? '' : ' from $ip';

  static String _formatTime(DateTime when) {
    final utc = when.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)} UTC';
  }

  static String _humanDuration(Duration duration) {
    if (duration.inDays >= 1) {
      final days = duration.inDays;
      return days == 1 ? '1 day' : '$days days';
    }
    if (duration.inHours >= 1) {
      final hours = duration.inHours;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    final minutes = duration.inMinutes;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }

  /// Names and role labels reach these templates from the database, so they
  /// are escaped before being interpolated — an HTML email is still a place
  /// where injected markup does damage.
  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _escapeAttribute(String value) => _escape(value);

  static String _stripTags(String value) => value
      .replaceAll(RegExp('<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"');
}

class _Action {
  const _Action(this.label, this.url);
  final String label;
  final String url;
}
