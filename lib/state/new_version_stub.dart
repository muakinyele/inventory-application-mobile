import 'package:flutter/foundation.dart';

/// True once a newer build has been deployed than the one running.
final ValueNotifier<bool> newVersionReady = ValueNotifier(false);

void watchForNewVersion() {}

void reloadToNewVersion() {}
