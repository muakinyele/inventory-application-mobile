// The browser check on web, nothing elsewhere: a phone app is updated by its
// store, not by reloading a page.
export 'new_version_stub.dart'
    if (dart.library.js_interop) 'new_version_web.dart';
