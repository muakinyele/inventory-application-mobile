import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'models/item.dart';
import 'data/snapshot.dart';
import 'state/auth_controller.dart';
import 'state/inventory_controller.dart';
import 'ui/account/account_page.dart';
import 'ui/account/notification_settings_page.dart';
import 'ui/account/security_page.dart';
import 'ui/activity_page.dart';
import 'ui/admin/audit_log_page.dart';
import 'ui/admin/user_detail_page.dart';
import 'ui/admin/users_page.dart';
import 'ui/alerts_page.dart';
import 'ui/app_shell.dart';
import 'ui/widgets/document_gate.dart';
import 'ui/auth/accept_invitation_page.dart';
import 'ui/auth/forgot_password_page.dart';
import 'ui/auth/login_page.dart';
import 'ui/auth/reset_password_page.dart';
import 'ui/auth/verify_email_page.dart';
import 'ui/categories_page.dart';
import 'ui/customers_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/invoice_detail_page.dart';
import 'ui/invoice_editor_page.dart';
import 'ui/invoices_page.dart';
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

/// A page that reads documents, behind the gate that fetches them.
///
/// Declared at the route rather than inside each page, so what a screen costs
/// to open is visible in one place — and so a page added later cannot forget
/// to ask and silently render an empty list.
Widget _withDocuments(Set<DocumentSet> need, Widget page) =>
    DocumentGate(need: need, builder: (_) => page);

/// Routes reachable without a session (§5).
///
/// Everything else is protected. Kept as a list rather than a set of checks
/// scattered through the pages, so "what is public?" has one answer that can
/// be read in one place.
const _publicRoutes = <String>[
  '/login',
  '/forgot-password',
  '/reset-password',
  '/accept-invitation',
  '/verify-email',
  '/verify-email-change',
];

bool _isPublic(String location) => _publicRoutes.any(
  (route) => location == route || location.startsWith('$route?'),
);

/// Real URLs on web: every page and item deep-links, and the browser's back
/// button behaves. Built per app instance rather than as a global so tests
/// each get a clean navigation stack.
///
/// [auth] drives the redirect guard. It is optional so a widget test can build
/// the router without standing up authentication; when it is null nothing is
/// protected, which is only ever the case in tests.
GoRouter createRouter({
  String initialLocation = '/',
  AuthController? auth,
}) => GoRouter(
  navigatorKey: GlobalKey<NavigatorState>(),
  initialLocation: initialLocation,
  // Re-evaluates every redirect when the session changes, so signing out
  // moves the app to the sign-in screen without any page having to watch for
  // it, and an expired session does the same from wherever the user was.
  refreshListenable: auth,
  redirect: auth == null ? null : (context, state) => _guard(auth, state),
  routes: [
    // ---- Public -----------------------------------------------------
    GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
    GoRoute(
      path: '/forgot-password',
      builder: (context, state) => const ForgotPasswordPage(),
    ),
    GoRoute(
      path: '/reset-password',
      builder: (context, state) =>
          ResetPasswordPage(token: state.uri.queryParameters['token']),
    ),
    GoRoute(
      path: '/accept-invitation',
      builder: (context, state) =>
          AcceptInvitationPage(token: state.uri.queryParameters['token']),
    ),
    GoRoute(
      path: '/verify-email',
      builder: (context, state) =>
          VerifyEmailPage(token: state.uri.queryParameters['token']),
    ),
    GoRoute(
      path: '/verify-email-change',
      builder: (context, state) => VerifyEmailPage(
        token: state.uri.queryParameters['token'],
        kind: VerificationKind.change,
      ),
    ),

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
              builder: (context, state) => _withDocuments(const {
                DocumentSet.transfers,
              }, const TransfersPage()),
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
              builder: (context, state) => _withDocuments(const {
                DocumentSet.purchaseOrders,
              }, const PurchaseOrdersPage()),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => const PurchaseOrderEditorPage(),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => _withDocuments(
                    const {DocumentSet.purchaseOrders},
                    PurchaseOrderDetailPage(
                      orderId: state.pathParameters['id']!,
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: 'edit',
                      builder: (context, state) => _withDocuments(
                        const {DocumentSet.purchaseOrders},
                        PurchaseOrderEditorPage(
                          orderId: state.pathParameters['id']!,
                        ),
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
              builder: (context, state) => _withDocuments(const {
                DocumentSet.salesOrders,
              }, const SalesOrdersPage()),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => const SalesOrderEditorPage(),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => _withDocuments(
                    const {
                      DocumentSet.salesOrders,
                      DocumentSet.receipts,
                      DocumentSet.invoices,
                    },
                    SalesOrderDetailPage(orderId: state.pathParameters['id']!),
                  ),
                  routes: [
                    GoRoute(
                      path: 'edit',
                      builder: (context, state) => _withDocuments(
                        const {DocumentSet.salesOrders},
                        SalesOrderEditorPage(
                          orderId: state.pathParameters['id']!,
                        ),
                      ),
                    ),
                    GoRoute(
                      path: 'view',
                      builder: (context, state) => _withDocuments(
                        const {DocumentSet.salesOrders},
                        SalesOrderDocumentPage(
                          orderId: state.pathParameters['id']!,
                        ),
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
              builder: (context, state) => _withDocuments(const {
                DocumentSet.receipts,
              }, const ReceiptsPage()),
              routes: [
                GoRoute(
                  path: 'new',
                  // `?sale=` raises the receipt against a sales order rather
                  // than as a counter sale, which fixes its lines to what
                  // that order actually sent.
                  builder: (context, state) => _withDocuments(
                    const {DocumentSet.salesOrders},
                    ReceiptEditorPage(
                      salesOrderId: state.uri.queryParameters['sale'],
                    ),
                  ),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => _withDocuments(const {
                    DocumentSet.receipts,
                  }, ReceiptDetailPage(receiptId: state.pathParameters['id']!)),
                  routes: [
                    GoRoute(
                      path: 'view',
                      builder: (context, state) => _withDocuments(
                        const {DocumentSet.receipts},
                        ReceiptDocumentPage(
                          receiptId: state.pathParameters['id']!,
                        ),
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
              path: '/invoices',
              builder: (context, state) => _withDocuments(const {
                DocumentSet.invoices,
              }, const InvoicesPage()),
              routes: [
                GoRoute(
                  path: 'new',
                  // `?sale=` bills a sales order rather than raising a
                  // standalone credit sale, which fixes the lines to what
                  // that order actually sent.
                  builder: (context, state) => _withDocuments(
                    const {DocumentSet.salesOrders},
                    InvoiceEditorPage(
                      salesOrderId: state.uri.queryParameters['sale'],
                    ),
                  ),
                ),
                GoRoute(
                  path: ':id',
                  // Sales orders too, to flag an invoice whose sale was
                  // cancelled; receipts, because a payment is a receipt and
                  // without them every payment looked unreceipted.
                  builder: (context, state) => _withDocuments(
                    const {
                      DocumentSet.invoices,
                      DocumentSet.salesOrders,
                      DocumentSet.receipts,
                    },
                    InvoiceDetailPage(
                      invoiceId: state.pathParameters['id']!,
                      openPayment: state.uri.queryParameters['pay'] == '1',
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: 'view',
                      builder: (context, state) => _withDocuments(
                        const {DocumentSet.invoices},
                        InvoiceDocumentPage(
                          invoiceId: state.pathParameters['id']!,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        _branch('/customers', CustomersPage.new),
        // Reports computes over all three, so it is the one screen that
        // genuinely needs more than its own list.
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/reports',
              builder: (context, state) => _withDocuments(const {
                DocumentSet.receipts,
                DocumentSet.invoices,
                DocumentSet.salesOrders,
              }, const ReportsPage()),
            ),
          ],
        ),

        // Administration. These sit at the indices `navItems` gives them, so
        // the sidebar's index-addressed selection keeps working.
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/users',
              builder: (context, state) => const UsersPage(),
              routes: [
                GoRoute(
                  path: ':id',
                  builder: (context, state) =>
                      UserDetailPage(userId: state.pathParameters['id']!),
                ),
              ],
            ),
          ],
        ),
        _branch('/audit-logs', AuditLogPage.new),

        // Pinned to the sidebar foot: Settings keeps index `navItems.length`,
        // and My Account follows it.
        _branch('/settings', SettingsPage.new),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/account',
              builder: (context, state) => const AccountPage(),
              routes: [
                GoRoute(
                  path: 'security',
                  builder: (context, state) => const SecurityPage(),
                ),
                GoRoute(
                  path: 'notifications',
                  builder: (context, state) => const NotificationSettingsPage(),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

/// The route guard (§5).
///
/// Three jobs, in order: hold everything while a stored session is being
/// restored, keep signed-out users out of the app, and keep signed-in users
/// out of the sign-in screens. Permission checks for the admin destinations
/// live here too, so a user who types `/users` gets the same answer as one who
/// cannot see it in the sidebar — and the API refuses them regardless.
String? _guard(AuthController auth, GoRouterState state) {
  final location = state.matchedLocation;

  // Restoring: stay put. `StockpileApp` is showing a splash over this, so no
  // redirect can flash the wrong screen at someone already signed in.
  if (auth.isRestoring) return null;

  if (!auth.isAuthenticated) {
    if (_isPublic(location)) return null;
    // Remembered so the user lands where they were going, not on the
    // dashboard, once they have signed in.
    auth.pendingRedirect = state.uri.toString();
    return '/login';
  }

  // Signed in. The sign-in and recovery screens are no longer meaningful, so
  // they redirect on — including via the browser's back button, which is what
  // stops a stale sign-in page being reachable behind a live session.
  if (location == '/login' || location == '/forgot-password') {
    final pending = auth.pendingRedirect;
    auth.pendingRedirect = null;
    return (pending != null && !_isPublic(Uri.parse(pending).path))
        ? pending
        : '/';
  }

  // Admin destinations. Hidden in the sidebar already; this closes the door on
  // a typed URL or a stale deep link.
  if (location.startsWith('/users') && !auth.can('users.view')) return '/';
  if (location.startsWith('/audit-logs') && !auth.can('audit_logs.view')) {
    return '/';
  }

  return null;
}

class StockpileApp extends StatefulWidget {
  const StockpileApp({super.key, this.initialLocation});

  /// Where to start, when the caller knows better than the browser does.
  ///
  /// Null in the app itself, so the address bar wins; the widget tests pass
  /// one because there is no address bar to read.
  final String? initialLocation;

  @override
  State<StockpileApp> createState() => _StockpileAppState();
}

class _StockpileAppState extends State<StockpileApp> {
  GoRouter? _router;

  /// Where the browser was pointing when the app started.
  ///
  /// REFRESHING ANY PAGE LANDED ON THE DASHBOARD, and this is why. The router
  /// is built only once the session has been restored — an async gap of a
  /// round trip — and by then the platform's own idea of the initial route is
  /// no longer available to go_router, so it fell back to the '/' it had been
  /// handed. Every reload therefore threw away the page you were on, and any
  /// link into the app deeper than the dashboard arrived at the dashboard.
  ///
  /// Read in `initState`, before that gap, so what the address bar said at
  /// entry survives the wait.
  ///
  /// ASSIGNED EAGERLY, NOT AS A `late final` INITIALISER. That form is lazy —
  /// it runs on first READ, which is inside `_routerFor`, i.e. after the
  /// restore — and by then the plain `MaterialApp` shown during the wait has
  /// already replaced the URL with the bare origin, because a non-Router app
  /// on web does not keep a route. So the lazy version read '/' and still
  /// landed on the dashboard, but only for someone with a session to restore:
  /// signed out there is no round trip, the splash never renders, and it
  /// appeared to work. Which is exactly how it passed on staging and failed in
  /// production.
  String? _entryLocation;

  @override
  void initState() {
    super.initState();
    _entryLocation = _locationFromBrowser();
  }

  /// The route in the address bar, or null when there is no address bar.
  ///
  /// The app uses the default hash strategy, so the route is the fragment:
  /// `https://host/#/invoices/new?sale=x` is `/invoices/new?sale=x`.
  static String? _locationFromBrowser() {
    if (!kIsWeb) return null;
    final fragment = Uri.base.fragment;
    if (fragment.isEmpty || fragment == '/') return null;
    return fragment.startsWith('/') ? fragment : '/$fragment';
  }

  /// Built once the session has been restored, and only then.
  ///
  /// Deferring it is what stops the guard evaluating against a controller that
  /// does not yet know whether anyone is signed in — which would send a
  /// returning user to the sign-in screen for a frame before bouncing them
  /// back.
  GoRouter _routerFor(AuthController? auth) => _router ??= createRouter(
    // An explicit one wins — that is a test saying where to start. Otherwise
    // the address bar, and only then the dashboard.
    initialLocation: widget.initialLocation ?? _entryLocation ?? '/',
    auth: auth,
  );

  @override
  Widget build(BuildContext context) {
    // Watched rather than read: the Appearance setting drives themeMode.
    final themeMode = context.select<InventoryController, ThemeMode>(
      (c) => c.settings.themeMode,
    );

    // Authentication is optional so the existing widget tests, which build the
    // app without a session, keep working unchanged.
    final auth = context.watch<AuthController?>();

    if (auth != null && auth.isRestoring) {
      return MaterialApp(
        title: 'Stockpile',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: themeMode,
        home: const _RestoringSession(),
      );
    }

    return MaterialApp.router(
      title: 'Stockpile',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      routerConfig: _routerFor(auth),
    );
  }
}

/// The splash shown while a stored session is checked against the server.
///
/// Deliberately plain: it is on screen for a fraction of a second on a warm
/// connection, and anything more would flash.
class _RestoringSession extends StatelessWidget {
  const _RestoringSession();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
