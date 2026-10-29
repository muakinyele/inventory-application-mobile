import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/theme.dart';
import 'data/inventory_api.dart';
import 'data/snapshot.dart';
import 'state/auth_controller.dart';
import 'state/inventory_controller.dart';
import 'state/live_refresh.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // The inventory is shared now, and it lives behind the same session as
    // everything else — so unlike before, there is nothing to read before
    // somebody has signed in. The catalogue is fetched once a session exists,
    // and again after signing in on a device that was signed out.
    final auth = buildAuthController();

    final inventory = InventoryController(
      InventoryApi(auth.api),
      Snapshot.empty,
    );

    // The catalogue follows the session: fetched when one appears, dropped
    // when it goes. Dropping matters on a shared terminal — whoever signs in
    // next must not find the last person's workspace on screen.
    auth.addListener(() {
      if (auth.isAuthenticated && inventory.load == InventoryLoad.idle) {
        unawaited(inventory.reload());
      } else if (!auth.isAuthenticated && !auth.isRestoring) {
        inventory.forgetSharedData();
      }
    });

    // Picks up what other devices and people change, without a reload.
    LiveRefresh(inventory);

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<InventoryController>.value(value: inventory),
          ChangeNotifierProvider<AuthController>.value(value: auth),
        ],
        child: const StockpileApp(),
      ),
    );

    // Started after the first frame so the splash is already on screen rather
    // than the window sitting blank while the server is asked about a stored
    // session. The listener above picks the catalogue up from there.
    unawaited(auth.restore());
  } catch (error, stack) {
    // Without this the app renders nothing at all when the database cannot be
    // opened — a blank white page that says neither what broke nor what to do.
    debugPrint('Stockpile: could not open the database: $error');
    debugPrintStack(stackTrace: stack);
    runApp(StartupFailureApp(error: error));
  }
}

/// Shown when the database cannot be opened or read. It states what happened
/// and offers the one recovery a user can actually perform.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.storage_rounded, size: 34),
                  const SizedBox(height: 16),
                  Text(
                    "Stockpile could not open its database",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your data has not been changed. This is almost always a '
                    'stale cached copy of the app running against a newer '
                    'database.',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'What to try, in order',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '1.  Hard-reload the page — Cmd/Ctrl + Shift + R.\n'
                    '2.  If that does not help, clear this site\u2019s data: '
                    'browser settings \u2192 Privacy \u2192 Clear browsing '
                    'data \u2192 Cached images and files, for this site.\n'
                    '3.  On a phone, close every tab for this address first, '
                    'so the old service worker is released.',
                    style: TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Technical detail',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
