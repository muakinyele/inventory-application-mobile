import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const bool canDownloadInBrowser = true;

/// Whether this browser can hand a file to other apps through its share
/// sheet. Chrome and Safari on a Mac, and phones, can; Firefox on a desktop
/// cannot, and there the file is downloaded instead.
bool canShareFilesInBrowser({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) {
  try {
    final file = web.File(
      [bytes.toJS].toJS,
      filename,
      web.FilePropertyBag(type: mimeType),
    );
    return web.window.navigator.canShare(web.ShareData(files: [file].toJS));
  } catch (_) {
    return false;
  }
}

/// Saves [bytes] to the browser's Downloads as [filename].
///
/// A temporary link with a `download` attribute, clicked and removed. Needs no
/// share sheet and no user gesture still being live, so it works however long
/// the PDF took to build.
Future<void> downloadInBrowser({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.append(link);
  link.click();
  link.remove();
  // Revoked after the click has been handed to the browser; revoking at once
  // can cancel the download in some browsers.
  await Future<void>.delayed(const Duration(seconds: 1));
  web.URL.revokeObjectURL(url);
}
