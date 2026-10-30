@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/data/browser_download.dart';
import 'package:stockpile/data/export_service.dart';

/// "Download PDF" and every export opened the macOS share menu in Chrome and
/// Safari, which cannot save a file. In a browser a download has to be a
/// download: a link with a `download` attribute, and the share sheet never
/// asked.
void main() {
  test(
    'a download in the browser saves the file, not the share sheet',
    () async {
      // Record any share attempt, and every link clicked with a filename.
      globalContext.callMethod(
        'eval'.toJS,
        '''
      window.__shares = 0;
      window.__downloads = [];
      Object.defineProperty(navigator, 'share', {
        configurable: true,
        value: () => { window.__shares++; return Promise.resolve(); },
      });
      Object.defineProperty(navigator, 'canShare', {
        configurable: true,
        value: () => true,
      });
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        if (this.download) window.__downloads.push(this.download);
        if (!this.download) click.call(this);
      };
      '''
            .toJS,
      );

      await const ExportService().shareBytes(
        filename: 'INV-0001.pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70]),
        mimeType: 'application/pdf',
      );
      await const ExportService().shareText(
        filename: 'items.csv',
        contents: 'name\nWidget',
        mimeType: 'text/csv',
      );

      final shares = (globalContext['__shares'] as JSNumber).toDartInt;
      final downloads = (globalContext['__downloads'] as JSArray<JSString>)
          .toDart
          .map((s) => s.toDart)
          .toList();
      expect(shares, 0, reason: 'the share sheet was opened');
      expect(downloads, ['INV-0001.pdf', 'items.csv']);
    },
  );

  test('a browser that can share files is offered the PDF itself', () {
    // Which way a Share goes: a browser that takes files gets the file; the
    // widget tests check that file is the PDF and not a text summary.
    globalContext.callMethod(
      'eval'.toJS,
      '''
      Object.defineProperty(navigator, 'canShare', {
        configurable: true,
        value: (d) => !!(d && d.files && d.files.length &&
            d.files[0].type === 'application/pdf'),
      });
      '''
          .toJS,
    );

    expect(
      canShareFilesInBrowser(
        bytes: Uint8List.fromList([37, 80, 68, 70]),
        filename: 'INV-0042.pdf',
        mimeType: 'application/pdf',
      ),
      isTrue,
    );
  });

  test('a browser that cannot share files downloads it instead', () async {
    globalContext.callMethod(
      'eval'.toJS,
      '''
      window.__downloads = [];
      Object.defineProperty(navigator, 'canShare', {
        configurable: true, value: () => false,
      });
      '''
          .toJS,
    );

    final outcome = await const ExportService().shareFile(
      filename: 'SO-0021.pdf',
      bytes: Uint8List.fromList([37, 80, 68, 70]),
      mimeType: 'application/pdf',
    );

    expect(outcome, FileShareOutcome.downloaded);
    final downloads = (globalContext['__downloads'] as JSArray<JSString>).toDart
        .map((s) => s.toDart);
    expect(downloads, ['SO-0021.pdf']);
  });
}
