import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'models/item.dart';
import 'state/inventory_controller.dart';
import 'ui/activity_page.dart';
import 'ui/alerts_page.dart';
import 'ui/app_shell.dart';
import 'ui/categories_page.dart';
import 'ui/customers_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/item_detail_page.dart';
import 'ui/item_editor_page.dart';
import 'ui/items_page.dart';
import 'ui/purchase_order_detail_page.dart';
import 'ui/purchase_order_editor_page.dart';
import 'ui/purchase_orders_page.dart';
import 'ui/receipt_detail_page.dart';
import 'ui/receipt_editor_page.dart';
import 'ui/receipts_page.dart';
import 'ui/reports_page.dart';
import 'ui/sales_order_detail_page.dart';
import 'ui/sales_order_editor_page.dart';
import 'ui/sales_orders_page.dart';
import 'ui/settings_page.dart';
import 'ui/transfer_editor_page.dart';
import 'ui/transfers_page.dart';
import 'ui/suppliers_page.dart';

/// Branch order matches the sidebar, so `navigationShell.currentIndex` is the
/// selected nav item without any URL re-parsing.
StatefulShellBranch _branch(String path, Widget Function() build) {
  return StatefulShellBranch(
    routes: [GoRoute(path: path, builder: (context, state) => build())],
  );
}

/// Real URLs on web: every page and item deep-links, and the browser's back
/// button behaves. Built per app instance rather than as a global so tests
/// each get a clean navigation stack.
GoRouter createRouter({String initialLocation = '/'}) => GoRouter(
  navigatorKey: GlobalKey<NavigatorState>(),
  initialLocation: initialLocation,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        _branch('/', DashboardPage.new),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/items',
              builder: (context, state) {
                final params = state.uri.queryParameters;
                return ItemsPage(
                  // A changed key rebuilds the page when another screen
                  // deep-links in with different query parameters.
                  key: ValueKey(state.uri.query),
                  initialStatus: switch (params['status']) {
                    'low' => StockStatus.low,
                    'out' => StockStatus.out,
                    'ok' => StockStatus.ok,
                    _ => null,
                  },
                  initialCategory: params['category'],
                  initialSupplierId: params['supplier'],
                  openScanner: params['scan'] == '1',
                );
              },
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => ItemEditorPage(
                    initialBarcode: state.uri.queryParameters['barcode'],
                  ),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) =>
                      ItemDetailPage(itemId: state.pathParameters['id']!),
                  routes: [
                    GoRoute(
                      path: 'edit',
                      builder: (context, state) =>
                          ItemEditorPage(itemId: state.pathParameters['id']!),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        _branch('/activity', ActivityPage.new),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/transfers',
              builder: (context, state) => const TransfersPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => const TransferEditorPage(),
                ),
              ],
            ),
          ],
        ),
        _branch('/categories', CategoriesPage.new),
        _branch('/alerts', AlertsPage.new),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/purchase-orders',
              builder: (context, state) => const PurchaseOrdersPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => const PurchaseOrderEditorPage(),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => PurchaseOrderDetailPage(
                    orderId: state.pathParameters['id']!,
                  ),
                  routes: [
                    GoRoute(
                      path: 'edit',
                      builder: (context, state) => PurchaseOrderEditorPage(
                        orderId: state.pathParameters['id']!,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        _branch('/suppliers', SuppliersPage.new),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/sales-orders',
              builder: (context, state) => const SalesOrdersPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => const SalesOrderEditorPage(),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => SalesOrderDetailPage(
                    orderId: state.pathParameters['id']!,
                  ),
                  routes: [
                    GoRoute(
                      path: 'edit',
                      builder: (context, state) => SalesOrderEditorPage(
                        orderId: state.pathParameters['id']!,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/receipts',
              builder: (context, state) => const ReceiptsPage(),
              routes: [
                GoRoute(
                  path: 'new',
                  // `?sale=` raises the receipt against a sales order rather
                  // than as a counter sale, which fixes its lines to what
                  // that order actually sent.
                  builder: (context, state) => ReceiptEditorPage(
                    salesOrderId: state.uri.queryParameters['sale'],
                  ),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) =>
                      ReceiptDetailPage(receiptId: state.pathParameters['id']!),
                ),
              ],
            ),
          ],
        ),
        _branch('/customers', CustomersPage.new),
        _branch('/reports', ReportsPage.new),
        _branch('/settings', SettingsPage.new),
      ],
    ),
  ],
);

class StockpileApp extends StatefulWidget {
  const StockpileApp({super.key, this.initialLocation = '/'});

  final String initialLocation;

  @override
  State<StockpileApp> createState() => _StockpileAppState();
}

class _StockpileAppState extends State<StockpileApp> {
  late final GoRouter _router = createRouter(
    initialLocation: widget.initialLocation,
  );

  @override
  Widget build(BuildContext context) {
    // Watched rather than read: the Appearance setting drives themeMode.
    final themeMode = context.select<InventoryController, ThemeMode>(
      (c) => c.settings.themeMode,
    );

    return MaterialApp.router(
      title: 'Stockpile',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      routerConfig: _router,
    );
  }
}
