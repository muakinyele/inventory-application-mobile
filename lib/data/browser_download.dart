// Chooses the browser implementation on web and a stub everywhere else, so
// the mobile builds never import browser APIs.
export 'browser_download_stub.dart'
    if (dart.library.js_interop) 'browser_download_web.dart';
