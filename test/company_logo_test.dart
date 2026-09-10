import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/logo_service.dart';
import 'package:stockpile/models/app_settings.dart';
import 'package:stockpile/core/theme.dart';
import 'package:stockpile/ui/widgets/company_logo_field.dart';

/// A 1×1 opaque PNG, as a base64 constant.
///
/// Widget tests use this rather than [makePng]: `Picture.toImage()` awaits a
/// rasterised frame, and inside a `testWidgets` body the binding drives the
/// clock, so nothing rasterises until `pump()` — awaiting it before the first
/// pump deadlocks the test and every one after it in the file.
const String tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// A real PNG of [width]×[height], produced by the same engine the app
/// decodes with — so these tests exercise actual image bytes rather than a
/// stand-in that only looks like one.
///
/// Safe in a plain `test()`, which has no frame-scheduling binding to wait on.
/// Do not call it from `testWidgets` — see [tinyPngBase64].
Future<Uint8List> makePng({
  int width = 40,
  int height = 40,
  Color colour = const Color(0xFF2A78D6),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = colour,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = LogoService();

  group('format detection reads the bytes, not the file name', () {
    test('recognises a real PNG', () async {
      expect(LogoService.detectFormat(await makePng()), 'png');
    });

    test('recognises a JPEG by its start-of-image marker', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
      expect(LogoService.detectFormat(jpeg), 'jpeg');
    });

    test('rejects other formats however they are labelled', () {
      // GIF, PDF, a ZIP (which is what a .docx really is), and plain text.
      final gif = Uint8List.fromList(utf8.encode('GIF89a...'));
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7'));
      final zip = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]);
      final text = Uint8List.fromList(utf8.encode('not an image at all'));

      for (final bytes in [gif, pdf, zip, text]) {
        expect(LogoService.detectFormat(bytes), isNull);
      }
    });

    test('rejects a file too short to carry a signature', () {
      expect(LogoService.detectFormat(Uint8List.fromList([0xFF])), isNull);
      expect(LogoService.detectFormat(Uint8List(0)), isNull);
    });

    test('a PNG signature with one byte wrong is not a PNG', () {
      final almost = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x00, // last byte differs
      ]);
      expect(LogoService.detectFormat(almost), isNull);
    });
  });

  group('validation', () {
    test('accepts a PNG and returns it encoded', () async {
      final result = await service.validate(await makePng());

      expect(result, isA<LogoAccepted>());
      final accepted = result as LogoAccepted;
      expect(accepted.encoded, isNotEmpty);
      expect(() => base64Decode(accepted.encoded), returnsNormally);
      expect(accepted.width, 40);
      expect(accepted.height, 40);
    });

    test('refuses anything over 5 MB, and says how big it was', () async {
      // Valid PNG signature, but far too large — so size is what stops it,
      // not the format.
      final huge = Uint8List(LogoService.maxBytes + 1)
        ..setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      final result = await service.validate(huge);

      expect(result, isA<LogoRejected>());
      final rejected = result as LogoRejected;
      expect(rejected.problem, LogoProblem.tooLarge);
      expect(rejected.message, contains('5.0 MB'));
    });

    test('the cap is inclusive: exactly 5 MB passes the size gate', () async {
      // Deliberately *not* a PNG, so this stops at the format check and never
      // reaches the decoder — handing it 5 MB of rubbish to parse is slow to
      // the point of looking hung.
      final atLimit = Uint8List(LogoService.maxBytes);

      final result = await service.validate(atLimit);

      expect(result, isA<LogoRejected>());
      expect(
        (result as LogoRejected).problem,
        LogoProblem.unsupportedFormat,
        reason: 'it got past the size check, so the size check allows 5 MB',
      );
    });

    test('refuses a format that is neither JPEG nor PNG', () async {
      final gif = Uint8List.fromList(utf8.encode('GIF89a and then some bytes'));
      final result = await service.validate(gif);

      expect(result, isA<LogoRejected>());
      final rejected = result as LogoRejected;
      expect(rejected.problem, LogoProblem.unsupportedFormat);
      expect(rejected.message, contains('JPEG or a PNG'));
      expect(
        rejected.message,
        contains('whatever its name says'),
        reason: 'the point is that the extension was not trusted',
      );
    });

    test('refuses an empty file', () async {
      final result = await service.validate(Uint8List(0));
      expect(result, isA<LogoRejected>());
      expect((result as LogoRejected).problem, LogoProblem.unreadable);
    });

    test('refuses bytes that claim PNG but will not decode', () async {
      final liar = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // valid signature
        ...List.filled(64, 0x00), // and then rubbish
      ]);

      final result = await service.validate(liar);
      expect(result, isA<LogoRejected>());
      expect((result as LogoRejected).problem, LogoProblem.unreadable);
    });

    test(
      'size is checked before format, so a huge non-image says "too large"',
      () async {
        final huge = Uint8List(LogoService.maxBytes + 1);
        final result = await service.validate(huge);
        expect((result as LogoRejected).problem, LogoProblem.tooLarge);
      },
    );
  });

  group('downscaling', () {
    test('caps the longest edge and keeps the aspect', () async {
      final wide = await makePng(width: 1600, height: 400);
      final result = await service.validate(wide) as LogoAccepted;

      expect(result.width, LogoService.maxEdge);
      expect(result.height, LogoService.maxEdge ~/ 4);
    });

    test('scales a tall logo by its height, not its width', () async {
      // Targeting width unconditionally would leave this far larger than the
      // cap, which is the bug this asserts against.
      final tall = await makePng(width: 300, height: 1200);
      final result = await service.validate(tall) as LogoAccepted;

      expect(result.height, LogoService.maxEdge);
      expect(result.width, LogoService.maxEdge ~/ 4);
    });

    test('leaves an already-small logo alone', () async {
      final small = await makePng(width: 120, height: 60);
      final result = await service.validate(small) as LogoAccepted;

      expect(result.width, 120);
      expect(result.height, 60);
    });

    test('a large upload is stored far smaller than it arrived', () async {
      final big = await makePng(width: 2000, height: 2000);
      final result = await service.validate(big) as LogoAccepted;

      expect(result.storedBytes, lessThan(result.originalBytes));
      expect(result.width, LogoService.maxEdge);
    });
  });

  group('the settings model', () {
    test('has no logo by default', () {
      const settings = AppSettings();
      expect(settings.companyLogo, isEmpty);
      expect(settings.hasCompanyLogo, isFalse);
    });

    test('round-trips through JSON', () async {
      final encoded = base64Encode(await makePng());
      final settings = const AppSettings().copyWith(companyLogo: encoded);

      final restored = AppSettings.fromJson(
        Map<String, dynamic>.from(settings.toJson()),
      );

      expect(restored.companyLogo, encoded);
      expect(restored.hasCompanyLogo, isTrue);
    });

    test('settings saved before logos existed still load', () {
      // The field is simply absent from the stored JSON.
      final legacy = <String, dynamic>{
        'companyName': 'Acme',
        'currency': 'NGN',
      };

      final restored = AppSettings.fromJson(legacy);
      expect(restored.companyName, 'Acme');
      expect(restored.hasCompanyLogo, isFalse);
    });

    test('an empty string removes it', () async {
      final withLogo = const AppSettings().copyWith(
        companyLogo: base64Encode(await makePng()),
      );
      expect(withLogo.hasCompanyLogo, isTrue);

      final cleared = withLogo.copyWith(companyLogo: '');
      expect(cleared.hasCompanyLogo, isFalse);
    });

    test('copyWith leaves it alone when not mentioned', () async {
      final encoded = base64Encode(await makePng());
      final settings = const AppSettings().copyWith(companyLogo: encoded);

      expect(settings.copyWith(companyName: 'Renamed').companyLogo, encoded);
    });
  });

  group('the settings field', () {
    Future<void> pumpField(
      WidgetTester tester, {
      required AppSettings settings,
      required LogoService service,
      required ValueChanged<String> onChanged,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyLogoField(
                settings: settings,
                onChanged: onChanged,
                service: service,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('states the rules up front', (tester) async {
      await pumpField(
        tester,
        settings: const AppSettings(),
        service: const LogoService(),
        onChanged: (_) {},
      );

      expect(find.textContaining('JPEG or PNG'), findsOneWidget);
      expect(find.textContaining('5.0 MB'), findsOneWidget);
    });

    testWidgets('offers upload and no remove when there is no logo', (
      tester,
    ) async {
      await pumpField(
        tester,
        settings: const AppSettings(),
        service: const LogoService(),
        onChanged: (_) {},
      );

      expect(find.text('Upload logo'), findsOneWidget);
      expect(find.text('Remove'), findsNothing);
      expect(find.text('No logo'), findsOneWidget);
    });

    testWidgets('previews the logo and offers replace and remove', (
      tester,
    ) async {
      final settings = const AppSettings().copyWith(companyLogo: tinyPngBase64);

      await pumpField(
        tester,
        settings: settings,
        service: const LogoService(),
        onChanged: (_) {},
      );

      expect(find.byType(Image), findsOneWidget, reason: 'the preview');
      expect(find.text('Replace logo'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('No logo'), findsNothing);
    });

    testWidgets('removing reports an empty string', (tester) async {
      String? reported;
      final settings = const AppSettings().copyWith(companyLogo: tinyPngBase64);

      await pumpField(
        tester,
        settings: settings,
        service: const LogoService(),
        onChanged: (value) => reported = value,
      );

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(reported, isEmpty);
    });

    testWidgets('shows the rejection message when a file is refused', (
      tester,
    ) async {
      await pumpField(
        tester,
        settings: const AppSettings(),
        service: _StubLogoService(
          const LogoRejected(
            LogoProblem.tooLarge,
            'That image is 8.0 MB. The largest a logo can be is 5.0 MB.',
          ),
        ),
        onChanged: (_) {},
      );

      await tester.tap(find.text('Upload logo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('largest a logo can be'), findsOneWidget);
    });

    testWidgets('reports what was kept after a successful upload', (
      tester,
    ) async {
      String? reported;
      await pumpField(
        tester,
        settings: const AppSettings(),
        service: _StubLogoService(
          const LogoAccepted(
            encoded: tinyPngBase64,
            width: 512,
            height: 128,
            originalBytes: 4 * 1024 * 1024,
            storedBytes: 40 * 1024,
          ),
        ),
        onChanged: (value) => reported = value,
      );

      await tester.tap(find.text('Upload logo'));
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(find.textContaining('512×128'), findsOneWidget);
      expect(find.textContaining('40 KB'), findsOneWidget);
      expect(find.textContaining('from 4.0 MB'), findsOneWidget);
    });

    testWidgets('a cancelled pick changes nothing and says nothing', (
      tester,
    ) async {
      var calls = 0;
      await pumpField(
        tester,
        settings: const AppSettings(),
        service: _StubLogoService(const LogoCancelled()),
        onChanged: (_) => calls++,
      );

      await tester.tap(find.text('Upload logo'));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.byIcon(Icons.error_rounded), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('a corrupt stored logo previews as broken, not as a crash', (
      tester,
    ) async {
      await pumpField(
        tester,
        settings: const AppSettings().copyWith(companyLogo: 'not base64 !!!'),
        service: const LogoService(),
        onChanged: (_) {},
      );

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });
  });
}

/// Returns a fixed outcome, so the field can be driven without a file picker.
class _StubLogoService implements LogoService {
  const _StubLogoService(this._result);

  final LogoResult _result;

  @override
  Future<LogoResult> pick() async => _result;

  @override
  Future<LogoResult> validate(Uint8List bytes) async => _result;
}
