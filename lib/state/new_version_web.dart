import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// True once a newer build has been deployed than the one running.
///
/// A deployed fix reached nobody who already had the app open: the page kept
/// running the code it loaded, so a bug fixed on the server went on happening
/// in that tab — imports that vanished, for one — until somebody happened to
/// reload. Each build stamps index.html with a hash of its code
/// (`flutter_bootstrap.js?v=<hash>`); this compares the stamp this page loaded
/// with the one being served now.
final ValueNotifier<bool> newVersionReady = ValueNotifier(false);

final _stamp = RegExp(r'flutter_bootstrap\.js\?v=([0-9a-f]+)');
Timer? _timer;
AppLifecycleListener? _listener;

void watchForNewVersion() {
  final running = _runningStamp();
  // A development build has no stamp, so there is nothing to compare.
  if (running == null || _timer != null) return;

  Future<void> check() async {
    if (newVersionReady.value) return;
    try {
      final response = await web.window
          .fetch('index.html'.toJS, web.RequestInit(cache: 'no-store'))
          .toDart;
      if (!response.ok) return;
      final html = (await response.text().toDart).toDart;
      final served = _stamp.firstMatch(html)?.group(1);
      if (served != null && served != running) newVersionReady.value = true;
    } catch (_) {
      // Offline, or the server is mid-deploy: try again next time.
    }
  }

  _timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
  // Held so it is not collected; a tab coming back into view checks at once.
  _listener ??= AppLifecycleListener(onResume: check, onShow: check);
}

void reloadToNewVersion() => web.window.location.reload();

String? _runningStamp() {
  final scripts = web.document.querySelectorAll('script[src]');
  for (var i = 0; i < scripts.length; i++) {
    final src = (scripts.item(i) as web.HTMLScriptElement?)?.src ?? '';
    final match = _stamp.firstMatch(src);
    if (match != null) return match.group(1);
  }
  return null;
}
