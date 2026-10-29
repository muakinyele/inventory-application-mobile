// The browser renderer on web, a stub elsewhere, so the phone builds never
// import browser APIs.
export 'browser_pdf_pages_stub.dart'
    if (dart.library.js_interop) 'browser_pdf_pages_web.dart';
