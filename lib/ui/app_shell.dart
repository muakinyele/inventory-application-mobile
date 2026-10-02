import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/design.dart';
import '../core/palette.dart';
import '../models/item.dart';
import '../state/auth_controller.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/shell_drawer.dart';
import 'widgets/inventory_status_banner.dart';
import 'widgets/confirm_dialog.dart';

/// Destinations promoted to the phone tab bar; the rest live behind "More".
///
/// Named by route and resolved to branch indices, so inserting a destination
/// in the sidebar can never silently promote the wrong one to the tab bar.
const _phoneRoutes = <String>['/', '/items', '/activity', '/alerts'];

/// Resolves a branch index to the destination it shows, including the two
/// pinned at the end that do not live in [navItems].
NavItem _itemFor(int branch) {
  if (branch == navItems.length) return settingsItem;
  if (branch == navItems.length + 1) return accountItem;
  return navItems[branch];
}

/// The destination that carries the reorder count. Named rather than indexed
/// for the same reason as above: the badge used to be pinned to a hardcoded
/// branch number, which quietly stopped matching when a destination was
/// inserted ahead of it and left the count showing on nothing at all.
const _alertsRoute = '/alerts';

final _phoneTabs = <int>[
  for (final route in _phoneRoutes)
    if (navItems.indexWhere((i) => i.route == route) >= 0)
      navItems.indexWhere((i) => i.route == route),
];

/// One navigation model, two presentations: a fixed dark sidebar once there is
/// room for it, and a tab bar plus overflow sheet on a phone. The sheet is the
/// tail of the same list rather than a second navigation system.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// Whether the sidebar is showing icons only.
  ///
  /// Remembered per device rather than per account: it is a preference about
  /// this screen's width, not about who is signed in.
  static const _collapsedKey = 'stockpile.sidebarCollapsed';

  /// Which section headings are folded away, by name.
  static const _sectionsKey = 'stockpile.collapsedNavSections';

  bool _collapsed = false;
  Set<String> _collapsedSections = const {};

  @override
  void initState() {
    super.initState();
    _restorePreferences();
  }

  Future<void> _restorePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final collapsed = prefs.getBool(_collapsedKey);
      final sections = prefs.getStringList(_sectionsKey);
      if (!mounted) return;
      setState(() {
        if (collapsed != null) _collapsed = collapsed;
        if (sections != null) _collapsedSections = sections.toSet();
      });
    } catch (_) {
      // A preference that cannot be read is not worth failing over; the rail
      // simply starts expanded with every section open.
    }
  }

  Future<void> _toggleSection(String section) async {
    final next = {..._collapsedSections};
    if (!next.remove(section)) next.add(section);
    setState(() => _collapsedSections = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_sectionsKey, next.toList());
    } catch (_) {
      // Fire and forget, like the rest of the app's persistence.
    }
  }

  Future<void> _toggleCollapsed() async {
    final next = !_collapsed;
    setState(() => _collapsed = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_collapsedKey, next);
    } catch (_) {
      // Fire and forget, like the rest of the app's persistence: the UI has
      // already moved, and a failed write only costs the choice next launch.
    }
  }

  StatefulNavigationShell get navigationShell => widget.navigationShell;

  void _go(int index) => navigationShell.goBranch(
    index,
    // Tapping the current destination again returns it to its root.
    initialLocation: index == navigationShell.currentIndex,
  );

  /// Ends the session and lets the router take it from there.
  ///
  /// No navigation here on purpose: `AuthController` is the router's
  /// refreshListenable, so the redirect guard moves to /login as soon as the
  /// status changes. Pushing a route as well would race that.
  Future<void> _signOut() async {
    final auth = context.read<AuthController?>();
    if (auth == null) return;

    final confirmed = await confirmAction(
      context,
      title: 'Sign out?',
      body:
          'You will need to sign in again on this device. Other devices stay '
          'signed in.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !mounted) return;

    try {
      await auth.signOut();
    } catch (error) {
      // The local session is cleared regardless — AuthApi.logout() forgets the
      // tokens even when the server cannot be reached — so this is only worth
      // saying, not worth blocking on. Staying on screen while signed out
      // would be the confusing outcome.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Signed out on this device; the server was not reached.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = context.watch<InventoryController>();
    // Nullable, and absence fails *closed*: with no session in scope the
    // permission predicate denies everything, so a shell built without
    // authentication (only ever a widget test) hides the admin destinations
    // rather than exposing them. The API enforces independently either way.
    final auth = context.watch<AuthController?>();
    bool can(String permission) => auth?.can(permission) ?? false;
    final alertCount = controller.items
        .where((i) => i.status != StockStatus.ok)
        .length;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebar;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            AppSidebar(
              selectedIndex: navigationShell.currentIndex,
              onSelect: _go,
              workspaceName: controller.settings.companyName,
              alertCount: alertCount,
              can: can,
              showAccount: auth != null,
              onSignOut: auth == null ? null : _signOut,
              collapsed: _collapsed,
              onToggleCollapsed: _toggleCollapsed,
              collapsedSections: _collapsedSections,
              onToggleSection: _toggleSection,
            ),
            Expanded(
              child: Column(
                children: [
                  // Above the content, not over it: neither message needs
                  // dismissing before work can carry on.
                  const InventoryStatusBanner(),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: Breakpoints.contentMax,
                        ),
                        child: navigationShell,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      drawer: Drawer(
        width: 260,
        child: AppSidebar(
          selectedIndex: navigationShell.currentIndex,
          onSelect: (index) {
            Navigator.of(context).pop();
            _go(index);
          },
          workspaceName: controller.settings.companyName,
          alertCount: alertCount,
          can: can,
          showAccount: auth != null,
          onSignOut: auth == null ? null : _signOut,
          collapsedSections: _collapsedSections,
          onToggleSection: _toggleSection,
        ),
      ),
      // The Builder is what makes this work: its context sits BELOW this
      // Scaffold, so `Scaffold.of` finds the one that actually has the drawer
      // rather than whichever Scaffold the page builds for itself.
      body: Builder(
        builder: (shellContext) => ShellDrawer(
          open: () => Scaffold.of(shellContext).openDrawer(),
          child: Column(
            children: [
              const InventoryStatusBanner(),
              Expanded(child: navigationShell),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _PhoneTabs(
        currentIndex: navigationShell.currentIndex,
        alertCount: alertCount,
        onSelect: _go,
        surface: p.surface,
        can: can,
        showAccount: auth != null,
        onSignOut: auth == null ? null : _signOut,
      ),
    );
  }
}

class _PhoneTabs extends StatelessWidget {
  const _PhoneTabs({
    required this.currentIndex,
    required this.alertCount,
    required this.onSelect,
    required this.surface,
    required this.can,
    required this.showAccount,
    this.onSignOut,
  });

  final int currentIndex;
  final int alertCount;
  final ValueChanged<int> onSelect;
  final Color surface;
  final bool Function(String permission) can;
  final bool showAccount;

  /// The sidebar is behind a drawer with no opener on a phone, so this sheet
  /// is the only place the control can live on small screens.
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // The overflow sheet is still the tail of the one list, minus whatever
    // this user cannot reach. Settings and My Account are pinned at the end,
    // matching the sidebar foot.
    final overflow = [
      for (var i = 0; i < navItems.length; i++)
        if (!_phoneTabs.contains(i) &&
            (navItems[i].permission == null || can(navItems[i].permission!)))
          i,
      navItems.length,
      if (showAccount) navItems.length + 1,
    ];
    final onOverflowPage = overflow.contains(currentIndex);

    // "More" is highlighted while any destination behind it is open, so the
    // bar never looks like nothing is selected.
    final selected = onOverflowPage
        ? _phoneTabs.length
        : _phoneTabs.indexOf(currentIndex);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: NavigationBar(
        selectedIndex: selected < 0 ? 0 : selected,
        onDestinationSelected: (i) {
          if (i < _phoneTabs.length) {
            onSelect(_phoneTabs[i]);
          } else {
            _openMore(context, overflow);
          }
        },
        destinations: [
          for (final branch in _phoneTabs)
            NavigationDestination(
              icon: navItems[branch].route == _alertsRoute && alertCount > 0
                  ? Badge.count(
                      count: alertCount,
                      backgroundColor: p.critical,
                      child: Icon(navItems[branch].icon),
                    )
                  : Icon(navItems[branch].icon),
              label: navItems[branch].label,
            ),
          const NavigationDestination(
            icon: Icon(Icons.more_horiz_rounded),
            label: 'More',
          ),
        ],
      ),
    );
  }

  Future<void> _openMore(BuildContext context, List<int> overflow) async {
    final p = context.palette;
    await showModalBottomSheet<void>(
      context: context,
      // Sizes to its contents rather than the default half-screen cap, which
      // the overflow list has outgrown. It still scrolls past the ceiling.
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xl,
                Insets.xs,
                Insets.xl,
                Insets.sm,
              ),
              child: Text(
                'More',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            // Scrolls rather than overflowing: the sheet is capped at half
            // the screen, and the overflow list grows as destinations are
            // added.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final branch in overflow)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Insets.xl,
                      ),
                      leading: Icon(
                        _itemFor(branch).icon,
                        color: currentIndex == branch
                            ? p.accent
                            : p.inkSecondary,
                      ),
                      title: Text(
                        _itemFor(branch).label,
                        style: TextStyle(
                          fontWeight: currentIndex == branch
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: currentIndex == branch ? p.accent : p.ink,
                        ),
                      ),
                      selected: currentIndex == branch,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onSelect(branch);
                      },
                    ),
                  if (onSignOut != null) ...[
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Insets.xl,
                      ),
                      leading: Icon(signOutItem.icon, color: p.inkSecondary),
                      title: Text(
                        signOutItem.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: p.ink,
                        ),
                      ),
                      onTap: () {
                        // Closed first: the confirmation is a dialog, and
                        // stacking it over a sheet that is about to be torn
                        // down by the sign-out redirect leaves it orphaned.
                        Navigator.of(sheetContext).pop();
                        onSignOut!();
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
          ],
        ),
      ),
    );
  }
}
