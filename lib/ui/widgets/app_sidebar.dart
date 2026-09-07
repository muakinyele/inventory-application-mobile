import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

class NavItem {
  const NavItem(this.route, this.label, this.icon, {this.section});
  final String route;
  final String label;
  final IconData icon;

  /// Heading this destination sits under. The first item of each run carries
  /// it; the rest repeat it so the list stays a flat, index-addressable set.
  final String? section;
}

/// The app's navigation destinations, in sidebar order. Settings is pinned to
/// the foot of the sidebar rather than sitting in this list.
const navItems = <NavItem>[
  NavItem('/', 'Dashboard', Icons.grid_view_rounded),

  NavItem('/items', 'Items', Icons.inventory_2_outlined, section: 'Stock'),
  NavItem('/activity', 'Activity', Icons.swap_horiz_rounded, section: 'Stock'),
  NavItem(
    '/transfers',
    'Transfers',
    Icons.compare_arrows_rounded,
    section: 'Stock',
  ),
  NavItem('/categories', 'Categories', Icons.sell_outlined, section: 'Stock'),
  NavItem(
    '/alerts',
    'Alerts',
    Icons.notifications_none_rounded,
    section: 'Stock',
  ),

  NavItem(
    '/purchase-orders',
    'Purchase Orders',
    Icons.receipt_long_outlined,
    section: 'Buying',
  ),
  NavItem(
    '/suppliers',
    'Suppliers',
    Icons.local_shipping_outlined,
    section: 'Buying',
  ),
  NavItem(
    '/sales-orders',
    'Sales Orders',
    Icons.request_quote_outlined,
    section: 'Selling',
  ),
  NavItem(
    '/receipts',
    'Receipts',
    Icons.receipt_rounded,
    section: 'Selling',
  ),
  NavItem('/customers', 'Customers', Icons.groups_outlined, section: 'Selling'),

  NavItem('/reports', 'Reports', Icons.bar_chart_rounded, section: 'Insights'),
];

const settingsItem = NavItem('/settings', 'Settings', Icons.settings_outlined);

/// The dark navigation rail. Used as a fixed column on wide windows and as the
/// contents of the drawer on narrow ones, so there is only one nav to maintain.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.workspaceName,
    this.alertCount = 0,
  });

  /// Index into [navItems], or `navItems.length` for Settings.
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final String workspaceName;
  final int alertCount;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      width: 260,
      color: p.sidebar,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Brand(workspaceName: workspaceName),
            Divider(height: 1, thickness: 1, color: p.sidebarLine),
            const SizedBox(height: Insets.md),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                children: [
                  for (final (index, item) in navItems.indexed) ...[
                    if (item.section != null &&
                        (index == 0 ||
                            navItems[index - 1].section != item.section))
                      _SectionLabel(item.section!),
                    _NavTile(
                      item: item,
                      selected: selectedIndex == index,
                      badge: item.route == '/alerts' && alertCount > 0
                          ? alertCount
                          : null,
                      onTap: () => onSelect(index),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: p.sidebarLine),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                Insets.md,
                Insets.md,
                Insets.lg,
              ),
              child: _NavTile(
                item: settingsItem,
                selected: selectedIndex == navItems.length,
                onTap: () => onSelect(navItems.length),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.md,
        Insets.md,
        Insets.xs,
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: context.palette.sidebarInkMuted.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.workspaceName});

  final String workspaceName;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.xl,
        Insets.lg,
        Insets.xl,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: p.brand,
              borderRadius: BorderRadius.circular(Radii.tile),
            ),
            child: const Icon(
              Icons.inventory_2_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              workspaceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: p.sidebarInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreground = selected ? Colors.white : p.sidebarInkMuted;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? p.sidebarActive : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.control),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.control),
            hoverColor: Colors.white.withValues(alpha: 0.06),
            focusColor: Colors.white.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: 11,
              ),
              child: Row(
                children: [
                  Icon(item.icon, size: 20, color: foreground),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                  if (badge != null) _Badge(count: badge!, selected: selected),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? Colors.white.withValues(alpha: 0.22) : p.critical,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
