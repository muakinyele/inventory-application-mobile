import 'dart:async';

import 'package:flutter/widgets.dart';

import 'inventory_controller.dart';

/// Keeps the screen in step with the server without a page reload.
///
/// The app reads the workspace once at sign-in and each list when it is
/// first opened. Without this, a change made on another device, in another
/// tab or by someone else never appeared until the page was reloaded.
///
/// Refreshes when the app comes back into view (a tab switched back to, a
/// window refocused, a phone app resumed) and on a timer while it is in
/// view. A hidden tab makes no requests.
class LiveRefresh {
  LiveRefresh(this._inventory, {this.every = const Duration(seconds: 30)}) {
    _listener = AppLifecycleListener(
      onResume: _onVisible,
      onShow: _onVisible,
      onHide: _stopTimer,
      onPause: _stopTimer,
    );
    _startTimer();
  }

  final InventoryController _inventory;
  final Duration every;
  late final AppLifecycleListener _listener;
  Timer? _timer;

  void _onVisible() {
    unawaited(_inventory.refreshFromServer());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      every,
      (_) => unawaited(_inventory.refreshFromServer()),
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _stopTimer();
    _listener.dispose();
  }
}
