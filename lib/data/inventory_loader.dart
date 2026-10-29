import 'package:flutter/material.dart' show ThemeMode;

import '../models/app_settings.dart';
import 'inventory_api.dart';
import 'snapshot.dart';

/// Builds the opening [Snapshot] from the shared inventory.
///
/// Online-only, as asked for: there is no local copy to fall back on, so a
/// failure here is a failure to start rather than something to paper over with
/// stale data. [loadSharedSnapshot] throws, and the caller decides what the
/// screen says.
///
/// Every list is fetched in parallel. They are independent, and doing them in
/// sequence would make startup the sum of nine round trips rather than the
/// slowest one. The catalogue is the exception: it pages, because the server
/// caps a page at 500 and asking once left a larger workspace with a
/// silently partial list behind every total in the app.
/// DOCUMENTS ARE NOT FETCHED HERE. Invoices, receipts, purchase orders, sales
/// orders and transfers used to come down with everything else, which meant
/// every sign-in paid for five document lists and all of their lines before
/// the dashboard could draw — and the dashboard reads none of them. A
/// workspace with a year of trading behind it waited on its whole history to
/// see today's stock.
///
/// They are fetched when a screen first asks, through
/// `InventoryController.ensureDocuments`.
Future<Snapshot> loadSharedSnapshot(InventoryApi api) async {
  final results = await Future.wait([
    api.allItems(),
    api.movements(),
    api.suppliers(),
    api.customers(),
    api.allStock(),
    api.preferences(),
  ]);

  final page = results[0] as ({List<dynamic> items, int total});

  return Snapshot(
    items: (page.items).cast(),
    movements: (results[1] as List).cast(),
    suppliers: (results[2] as List).cast(),
    customers: (results[3] as List).cast(),
    purchaseOrders: const [],
    salesOrders: const [],
    receipts: const [],
    invoices: const [],
    transfers: const [],
    levels: (results[4] as Map).cast<String, Map<String, int>>(),
    // Sequences are the server's now: it allocates every document reference
    // inside the transaction that writes the document, so a client-side
    // counter would only ever be a stale second opinion.
    sequences: const {},
    settings: await _settingsFrom(api, results[5] as Map<String, String>),
  );
}

/// Assembles [AppSettings] from the three places the server keeps it.
///
/// Preferences hold the scalars, categories carry their own colour and order,
/// and the pickers are lookup lists. That split mirrors how it was stored on
/// device, so the shapes the rest of the app reads do not change.
Future<AppSettings> _settingsFrom(
  InventoryApi api,
  Map<String, String> prefs,
) async {
  final categories = await api.categories();
  final locations = await api.lookupValues('location');
  final units = await api.lookupValues('unit');

  return AppSettings(
    companyName: prefs['companyName'] ?? 'My Inventory',
    currency: prefs['currency'] ?? 'NGN',
    companyAddress: prefs['companyAddress'] ?? '',
    companyPhone: prefs['companyPhone'] ?? '',
    companyEmail: prefs['companyEmail'] ?? '',
    taxRate: double.tryParse(prefs['taxRate'] ?? '')?.clamp(0, 1) ?? 0,
    taxLabel: prefs['taxLabel']?.isNotEmpty == true
        ? prefs['taxLabel']!
        : 'VAT',
    receiptFooter: prefs['receiptFooter'] ?? 'Thank you for your custom.',
    // The other half of the same omission: written now, so it has to be read.
    companyLogo: prefs['companyLogo'] ?? '',
    // Deliberately still per-device: which theme this screen uses is not a
    // property of the workspace, and syncing it would change one person's
    // display because another changed theirs.
    themeMode: ThemeMode.system,
    categories: [for (final c in categories) c.name],
    locations: locations.isEmpty ? AppSettings.defaultLocations : locations,
    units: units.isEmpty ? AppSettings.defaultUnits : units,
    categoryColors: {for (final c in categories) c.name: c.swatchIndex},
  );
}
