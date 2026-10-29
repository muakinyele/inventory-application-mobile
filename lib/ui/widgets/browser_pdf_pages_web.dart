import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// In a browser the pages are drawn here rather than by the printing plugin.
///
/// The plugin loads pdf.js from unpkg.com through `eval`. The page's
/// Content-Security-Policy allows neither, so its setup threw, and because it
/// never releases its lock when that happens, every preview after it waited
/// forever: the document page span and showed nothing. This loads the copy
/// served from the app's own origin (`web/pdfjs/`) with a plain module import,
/// and tells pdf.js not to use eval either.
const bool rendersPdfInBrowser = true;

JSObject? _pdfjs;

Future<JSObject> _load() async {
  final loaded = _pdfjs;
  if (loaded != null) return loaded;
  final base = Uri.base.resolve('pdfjs/');
  final lib = await importModule(
    base.resolve('pdf.min.mjs').toString().toJS,
  ).toDart;
  final options = lib['GlobalWorkerOptions'] as JSObject;
  options['workerSrc'] = base.resolve('pdf.worker.min.mjs').toString().toJS;
  return _pdfjs = lib;
}

/// Renders every page of [pdf] to a PNG at [dpi].
Future<List<Uint8List>> rasterPdfInBrowser(
  Uint8List pdf, {
  required double dpi,
}) async {
  final lib = await _load();
  final params = JSObject()
    // A copy: pdf.js hands the buffer to its worker, which detaches it.
    ..['data'] = Uint8List.fromList(pdf).toJS
    ..['isEvalSupported'] = false.toJS
    ..['standardFontDataUrl'] = Uri.base
        .resolve('pdfjs/standard_fonts/')
        .toString()
        .toJS;
  final task = lib.callMethod<JSObject>('getDocument'.toJS, params);
  final doc = await (task['promise'] as JSPromise<JSObject>).toDart;

  try {
    final count = (doc['numPages'] as JSNumber).toDartInt;
    final pages = <Uint8List>[];
    for (var number = 1; number <= count; number++) {
      final page = await doc
          .callMethod<JSPromise<JSObject>>('getPage'.toJS, number.toJS)
          .toDart;
      final viewport = page.callMethod<JSObject>(
        'getViewport'.toJS,
        JSObject()..['scale'] = (dpi / 72).toJS,
      );
      final width = (viewport['width'] as JSNumber).toDartDouble.ceil();
      final height = (viewport['height'] as JSNumber).toDartDouble.ceil();

      final canvas = web.HTMLCanvasElement()
        ..width = width
        ..height = height;
      final context = canvas.getContext('2d')!;
      final render = page.callMethod<JSObject>(
        'render'.toJS,
        JSObject()
          ..['canvas'] = canvas
          ..['canvasContext'] = context
          ..['viewport'] = viewport,
      );
      await (render['promise'] as JSPromise).toDart;
      pages.add(await _png(canvas));
      page.callMethod('cleanup'.toJS);
    }
    return pages;
  } finally {
    doc.callMethod('destroy'.toJS);
  }
}

Future<Uint8List> _png(web.HTMLCanvasElement canvas) async {
  final done = Completer<web.Blob?>();
  canvas.toBlob(((web.Blob? blob) => done.complete(blob)).toJS, 'image/png');
  final blob = await done.future;
  if (blob == null) throw StateError('The page could not be drawn.');
  final buffer = await blob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
