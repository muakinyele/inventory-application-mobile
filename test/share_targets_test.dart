import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/share_targets.dart';

void main() {
  group('WhatsApp links', () {
    // wa.me takes DIGITS. A '+' or a space in the path does not error — the
    // link opens and WhatsApp says the number is invalid, which reads to the
    // sender as the app being broken.
    test('a number is reduced to digits', () {
      final uri = whatsAppUri('Hello', phone: '+234 802 123 4567');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/2348021234567');
    });

    test('dashes and brackets go too', () {
      final uri = whatsAppUri('Hello', phone: '(0803) 555-0199');
      expect(uri.path, '/08035550199');
    });

    test('a 00 international prefix becomes nothing', () {
      // 00 and + are the same thing written differently; wa.me wants neither.
      final uri = whatsAppUri('Hello', phone: '00234802123456');
      expect(uri.path, '/234802123456');
    });

    test('no number at all leaves the recipient to be picked', () {
      final uri = whatsAppUri('Hello');
      expect(uri.path, '/');
      expect(uri.queryParameters['text'], 'Hello');
    });

    test('the message survives newlines and punctuation', () {
      // A receipt summary is multi-line and full of currency symbols; if this
      // is mangled the customer gets an unreadable message.
      const summary =
          'Acme Ltd — receipt RC-0042\n2 × Bolt — ₦1,500\nTotal: ₦3,000';
      final uri = whatsAppUri(summary);

      expect(uri.queryParameters['text'], summary);
      expect(
        uri.toString(),
        isNot(contains('\n')),
        reason: 'a raw newline in a URL truncates it',
      );
    });

    test('an ampersand in the text does not start a new parameter', () {
      final uri = whatsAppUri('Bolts & nuts');
      expect(uri.queryParameters['text'], 'Bolts & nuts');
    });
  });

  group('mailto links', () {
    test('subject and body are carried', () {
      final uri = mailtoUri(
        subject: 'Invoice INV-0007',
        body: 'Balance due: 1,200',
        to: 'buyer@example.com',
      );

      expect(uri.scheme, 'mailto');
      expect(uri.path, 'buyer@example.com');
      expect(uri.queryParameters['subject'], 'Invoice INV-0007');
      expect(uri.queryParameters['body'], 'Balance due: 1,200');
    });

    test('spaces in a subject are percent-encoded, not plus-encoded', () {
      // Uri(queryParameters:) would write '+', which mail clients show
      // literally in the subject line.
      final uri = mailtoUri(subject: 'Invoice INV-0007', body: 'x');
      expect(uri.toString(), contains('subject=Invoice%20INV-0007'));
      expect(uri.toString(), isNot(contains('+')));
    });

    test('no address still opens a compose window', () {
      final uri = mailtoUri(subject: 'S', body: 'B');
      expect(uri.path, '');
    });
  });

  group('sms links', () {
    test('the body is carried and the number kept', () {
      final uri = smsUri('Your receipt', phone: '+2348021234567');
      expect(uri.scheme, 'sms');
      expect(uri.queryParameters['body'], 'Your receipt');
    });
  });

  group('telegram links', () {
    test('the url and note are both encoded', () {
      final uri = telegramUri(
        url: 'https://example.com/r/1?a=b',
        text: 'Receipt RC-1',
      );
      expect(uri.queryParameters['url'], 'https://example.com/r/1?a=b');
      expect(uri.queryParameters['text'], 'Receipt RC-1');
    });
  });
}
