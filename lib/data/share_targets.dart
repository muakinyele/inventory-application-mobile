import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Deep links into the apps people forward documents with.
///
/// WHAT A DEEP LINK CAN AND CANNOT CARRY, because the difference decides the
/// whole design of the share sheet above this.
///
/// `wa.me`, `mailto:` and `sms:` carry TEXT. None of them can attach a file:
/// WhatsApp's click-to-chat API has no file parameter, and no amount of
/// encoding invents one. A browser cannot hand a PDF to WhatsApp Web either.
///
/// So a document leaves by one of two routes, and they are labelled
/// differently on purpose rather than both being called "share":
///
///   * the system share sheet, which hands the actual file to whichever app
///     the person picks — WhatsApp included, on a phone;
///   * a deep link carrying a written summary, for when the point is to tell
///     somebody the total rather than to send them the paperwork.
///
/// Offering the first as "WhatsApp" would promise an attachment that never
/// arrives; offering only the second would make the app look unable to send a
/// document at all.

/// A chat message to a WhatsApp number, or to whoever the sender picks.
///
/// [phone] is a full international number WITHOUT a leading `+`, `00`, spaces
/// or dashes — wa.me takes digits only and silently fails on anything else,
/// which is why this strips rather than trusts. Omitted, WhatsApp asks the
/// sender to choose a contact, which is what you want from a document screen
/// where the recipient is not necessarily the one on file.
Uri whatsAppUri(String text, {String? phone}) {
  final digits = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  // A number that began 00 is the international prefix written the old way.
  final normalised = digits.startsWith('00') ? digits.substring(2) : digits;
  return Uri.parse(
    'https://wa.me/$normalised?text=${Uri.encodeComponent(text)}',
  );
}

/// An email, addressed if there is an address to hand.
Uri mailtoUri({required String subject, required String body, String? to}) =>
    Uri(
      scheme: 'mailto',
      path: to ?? '',
      // queryParameters would encode the spaces in a subject as '+', which
      // mail clients show literally.
      query:
          'subject=${Uri.encodeComponent(subject)}'
          '&body=${Uri.encodeComponent(body)}',
    );

/// A text message, for the customer who does not use anything else.
Uri smsUri(String text, {String? phone}) {
  final digits = (phone ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
  return Uri.parse('sms:$digits?body=${Uri.encodeComponent(text)}');
}

/// A Telegram share, which takes a URL and an optional note beside it.
Uri telegramUri({required String url, String? text}) => Uri.parse(
  'https://t.me/share/url?url=${Uri.encodeComponent(url)}'
  '&text=${Uri.encodeComponent(text ?? '')}',
);

/// Opens [target], and says whether anything took it.
///
/// A new tab on the web and the installed app elsewhere: `wa.me` resolves to
/// WhatsApp when it is installed and to the web client when it is not, so the
/// same link works on a phone without WhatsApp and on a desktop.
///
/// Returns false rather than throwing when nothing can open it — a desktop
/// with no mail client, a browser that blocked the popup — so the caller can
/// say so instead of failing silently.
Future<bool> openShareTarget(Uri target) async {
  try {
    return await launchUrl(
      target,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
  } catch (error) {
    debugPrint('Stockpile: could not open $target: $error');
    return false;
  }
}
