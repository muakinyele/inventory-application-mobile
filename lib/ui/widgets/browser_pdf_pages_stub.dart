import 'dart:typed_data';

/// Off the web the printing plugin rasters natively, so this is never used.
const bool rendersPdfInBrowser = false;

Future<List<Uint8List>> rasterPdfInBrowser(
  Uint8List pdf, {
  required double dpi,
}) async => throw UnsupportedError('Only available in a browser.');
