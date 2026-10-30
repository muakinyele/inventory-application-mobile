import 'dart:typed_data';

/// Not a browser: there is no Downloads folder to save into, so the caller
/// uses the share sheet instead.
const bool canDownloadInBrowser = false;

/// Off the web, the system share sheet always takes a file.
bool canShareFilesInBrowser({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) => true;

Future<void> downloadInBrowser({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) async {
  throw UnsupportedError('Only available in a browser.');
}
