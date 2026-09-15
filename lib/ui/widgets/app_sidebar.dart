// Material ships its own `Durations`, which would shadow the project's
// design token of the same name. The project's scale is what the rest of
// the app animates on, so Material's is hidden rather than the token
// aliased.
import 'package:flutter/material.dart' hide Durations;

import '../../core/design.dart';
import '../../core/palette.dart';

class NavItem {
  const NavItem(
    this.route,
    this.label,
    this.icon, {
    this.section,
    this.permission,
  });

  final String route;
  final String label;
  final IconData icon;

  /// Heading this destination sits under. The first item of each run carries
  /// it; the rest repeat it so the list stays a flat, index-addressable set.
  final String? section;

  /// Hidden unless the signed-in user holds this permission. Null means every
  /// signed-in user sees it.
  ///
  /// Hiding is presentation only. The destination's own screen and the API
  /// behind it both check again — this just keeps the sidebar honest about
  /// what the person can actually reach.
  final String? permission;
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
  NavItem('/receipts', 'Receipts', Icons.receipt_rounded, section: 'Selling'),
  NavItem(
    '/invoices',
    'Invoices',
    Icons.description_outlined,
    section: 'Selling',
  ),
  NavItem('/customers', 'Customers', Icons.groups_outlined, section: 'Selling'),

  NavItem('/reports', 'Reports', Icons.bar_chart_rounded, section: 'Insights'),

  NavItem(
    '/users',
    'Users',
    Icons.people_alt_outlined,
    section: 'Administration',
    permission: 'users.view',
  ),
  NavItem(
    '/audit-logs',
    'Audit Log',
    Icons.history_rounded,
    section: 'Administration',
    permission: 'audit_logs.view',
  ),
];

const settingsItem = NavItem('/settings', 'Settings', Icons.settings_outlined);

/// Pinned to the sidebar foot beside Settings, rather than sitting in
/// [navItems]: it is where you go to manage yourself, not a place in the
/// workspace.
/// Not a destination: nothing routes here, and [_NavTile] reads only the icon
/// and the label. It is a NavItem so the action is styled identically to the
/// tiles above it rather than being a lookalike that drifts out of step.
const signOutItem = NavItem('', 'Sign out', Icons.logout_outlined);

const accountItem = NavItem(
  '/account',
  'My account',
  Icons.account_circle_outlined,
);

/// Width of the rail when it is showing labels.
const double sidebarExpandedWidth = 260;

/// Width when collapsed to icons. Wide enough for a 44px tap target plus the
/// breathing room the rest of the app uses.
const double sidebarCollapsedWidth = 76;

/// The dark navigation rail. Used as a fixed column on wide windows and as the
/// contents of the drawer on narrow ones, so there is only one nav to maintain.
///
/// The column can be collapsed to icons ([collapsed]), which buys back about
/// 185px of horizontal space for the tables and charts beside it. Collapsing
/// also drops the section headings, so the whole list fits without scrolling
/// on a short window — which is what stops the last destination hiding under
/// the footer.
///
/// The drawer presentation never collapses: it is already a temporary overlay
/// with the full width available, so there would be nothing to gain.
class AppSidebar extends StatefulWidget {
  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.workspaceName,
    required this.can,
    this.showAccount = true,
    this.onSignOut,
    this.alertCount = 0,
    this.collapsed = false,
    this.onToggleCollapsed,
    this.collapsedSections = const {},
    this.onToggleSection,
  });

  /// Index into [navItems]; `navItems.length` is Settings and
  /// `navItems.length + 1` is My Account.
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final String workspaceName;
  final int alertCount;

  /// Whether the signed-in user holds a permission. Destinations that name one
  /// are hidden when they do not.
  final bool Function(String permission) can;

  /// False when there is no session in scope, so the account destination is
  /// not offered. Only a widget test built without authentication sees this.
  final bool showAccount;

  /// Ends the session. Null hides the control — there is nothing to sign out
  /// of when no session is in scope, which is the case in widget tests that
  /// build the shell without authentication.
  final VoidCallback? onSignOut;

  /// Icons only, no labels.
  final bool collapsed;

  /// Null hides the toggle entirely — which is how the drawer presentation
  /// opts out of collapsing.
  final VoidCallback? onToggleCollapsed;

  /// Section headings whose destinations are folded away, by name.
  ///
  /// Only meaningful while the rail is showing labels: collapsed to icons
  /// there are no headings to fold under, so the whole list stays visible.
  final Set<String> collapsedSections;

  /// Null makes the headings plain labels again, which is what a caller that
  /// has nowhere to keep the state should pass.
  final ValueChanged<String>? onToggleSection;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> {
  /// Owned here so the scrollbar can be pinned to this list specifically —
  /// `thumbVisibility` needs a controller it can attach to.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selectedIndex = widget.selectedIndex;
    final onSelect = widget.onSelect;
    final collapsed = widget.collapsed;
    final alertCount = widget.alertCount;
    final can = widget.can;
    final showAccount = widget.showAccount;
    final onToggleSection = widget.onToggleSection;

    // Filtered up front, keeping each item's original index: the index is
    // what addresses the router's branch, so it must survive hiding a
    // destination above it.
    final visible = [
      for (final (index, item) in navItems.indexed)
        if (item.permission == null || can(item.permission!)) (index, item),
    ];

    // The section holding the current destination is never folded away, so
    // wherever you are is always visible and shown as selected. Without this,
    // arriving at a route by URL or by redirect could leave the rail looking
    // as though nothing is selected at all.
    final selectedSection = visible
        .where((entry) => entry.$1 == selectedIndex)
        .map((entry) => entry.$2.section)
        .firstOrNull;

    bool sectionIsFolded(String? section) =>
        section != null &&
        !collapsed &&
        onToggleSection != null &&
        section != selectedSection &&
        widget.collapsedSections.contains(section);

    return AnimatedContainer(
      duration: Durations.normal,
      curve: Curves.easeOutCubic,
      width: collapsed ? sidebarCollapsedWidth : sidebarExpandedWidth,
      color: p.sidebar,
      child: SafeArea(
        right: false,
        // The rail animates between two widths, and mid-animation it is
        // narrower than the expanded content wants to be. Clipping keeps that
        // from painting an overflow stripe across the transition.
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: collapsed ? sidebarCollapsedWidth : sidebarExpandedWidth,
            maxWidth: collapsed ? sidebarCollapsedWidth : sidebarExpandedWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Brand(
                  workspaceName: widget.workspaceName,
                  collapsed: collapsed,
                  onToggleCollapsed: widget.onToggleCollapsed,
                ),
                Divider(height: 1, thickness: 1, color: p.sidebarLine),
                const SizedBox(height: Insets.md),
                Expanded(
                  // A rail with this many destinations can outgrow a short
                  // window. The scrollbar is what stops the last one looking
                  // like it simply is not there.
                  // Raw rather than plain `Scrollbar` so the thumb can be
                  // coloured for this surface: the Material default is a dark
                  // translucent grey, which is invisible on the dark rail.
                  child: RawScrollbar(
                    controller: _scrollController,
                    // Always drawn when there is anything to scroll to. With
                    // fifteen destinations the list outgrows a short window,
                    // and a silently clipped last item reads as missing
                    // rather than as scrolled past. Nothing is painted when
                    // the content fits, so the collapsed rail — which does
                    // fit — stays clean.
                    thumbVisibility: true,
                    thumbColor: Colors.white.withValues(alpha: 0.22),
                    thickness: 4,
                    radius: const Radius.circular(Radii.pill),
                    crossAxisMargin: 2,
                    child: ListView(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: collapsed ? Insets.sm : Insets.md,
                      ),
                      children: [
                        for (final (position, entry) in visible.indexed) ...[
                          // The heading is carried by the first *visible* item
                          // of a run, not the first item of the run — otherwise
                          // hiding an admin destination would take its section
                          // label with it and orphan the one below.
                          if (entry.$2.section != null &&
                              (position == 0 ||
                                  visible[position - 1].$2.section !=
                                      entry.$2.section))
                            collapsed
                                // Collapsed, a heading has nowhere to go, so the
                                // grouping is carried by a rule instead. The
                                // first group needs none — there is a divider
                                // above it already.
                                ? (position == 0
                                      ? const SizedBox.shrink()
                                      : _GroupRule(colour: p.sidebarLine))
                                : _SectionHeader(
                                    title: entry.$2.section!,
                                    folded: sectionIsFolded(entry.$2.section),
                                    // Pinned open because it holds the current
                                    // destination — the chevron says so rather
                                    // than just refusing to move.
                                    pinnedOpen:
                                        entry.$2.section == selectedSection &&
                                        widget.collapsedSections.contains(
                                          entry.$2.section,
                                        ),
                                    onTap: onToggleSection == null
                                        ? null
                                        : () => onToggleSection(
                                            entry.$2.section!,
                                          ),
                                  ),
                          if (!sectionIsFolded(entry.$2.section))
                            _NavTile(
                              item: entry.$2,
                              selected: selectedIndex == entry.$1,
                              collapsed: collapsed,
                              badge:
                                  entry.$2.route == '/alerts' && alertCount > 0
                                  ? alertCount
                                  : null,
                              onTap: () => onSelect(entry.$1),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, thickness: 1, color: p.sidebarLine),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    collapsed ? Insets.sm : Insets.md,
                    Insets.md,
                    collapsed ? Insets.sm : Insets.md,
                    Insets.lg,
                  ),
                  child: Column(
                    children: [
                      if (showAccount) ...[
                        _NavTile(
                          item: accountItem,
                          selected: selectedIndex == navItems.length + 1,
                          collapsed: collapsed,
                          onTap: () => onSelect(navItems.length + 1),
                        ),
                        const SizedBox(height: Insets.xs),
                      ],
                      _NavTile(
                        item: settingsItem,
                        selected: selectedIndex == navItems.length,
                        collapsed: collapsed,
                        onTap: () => onSelect(navItems.length),
                      ),
                      if (widget.onSignOut != null) ...[
                        const SizedBox(height: Insets.xs),
                        _NavTile(
                          item: signOutItem,
                          // Never selected: it is an action, not somewhere you
                          // can be.
                          selected: false,
                          collapsed: collapsed,
                          onTap: widget.onSignOut!,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in for a section heading when the rail is collapsed.
class _GroupRule extends StatelessWidget {
  const _GroupRule({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Divider(height: 1, thickness: 1, color: colour),
    );
  }
}

/// A section heading. Tappable when the caller can remember the fold state,
/// a plain label when it cannot.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.folded,
    required this.onTap,
    this.pinnedOpen = false,
  });

  final String title;
  final bool folded;
  final VoidCallback? onTap;

  /// Held open because the current destination lives in it.
  final bool pinnedOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = p.sidebarInkMuted.withValues(alpha: 0.75);

    final label = Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: colour,
      ),
    );

    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.md,
          Insets.md,
          Insets.xs,
        ),
        child: label,
      );
    }

    return Semantics(
      button: true,
      expanded: !folded,
      label: title,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.control),
          hoverColor: Colors.white.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.md,
              Insets.sm,
              Insets.xs,
            ),
            child: Row(
              children: [
                Expanded(child: label),
                if (pinnedOpen)
                  // The group is folded but shown anyway. Saying so is kinder
                  // than a chevron that appears not to work.
                  Padding(
                    padding: const EdgeInsets.only(right: Insets.xs),
                    child: Icon(
                      Icons.push_pin_outlined,
                      size: 11,
                      color: colour,
                    ),
                  ),
                AnimatedRotation(
                  duration: Durations.fast,
                  turns: folded ? -0.25 : 0,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: colour,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({
    required this.workspaceName,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final String workspaceName;
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final mark = Container(
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
    );

    final toggle = onToggleCollapsed == null
        ? null
        : _RailToggle(collapsed: collapsed, onPressed: onToggleCollapsed!);

    if (collapsed) {
      // Stacked rather than side by side: at 76px there is no room for both,
      // and the toggle has to stay reachable or the rail cannot be reopened.
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.sm,
          Insets.md,
          Insets.sm,
          Insets.sm,
        ),
        child: Column(
          children: [
            mark,
            if (toggle != null) ...[const SizedBox(height: Insets.sm), toggle],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.xl,
        Insets.md,
        Insets.xl,
      ),
      child: Row(
        children: [
          mark,
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
          if (toggle != null) ...[const SizedBox(width: Insets.xs), toggle],
        ],
      ),
    );
  }
}

/// The collapse/expand control.
class _RailToggle extends StatelessWidget {
  const _RailToggle({required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = collapsed ? 'Expand menu' : 'Collapse menu';

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.control),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(Radii.control),
            hoverColor: Colors.white.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: Icon(
                collapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 20,
                color: p.sidebarInkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
    this.badge,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreground = selected ? Colors.white : p.sidebarInkMuted;

    final icon = Icon(item.icon, size: 20, color: foreground);

    final content = collapsed
        ? SizedBox(
            // Tight enough that the whole list clears a 13" laptop without
            // scrolling, still a comfortable 40px target.
            height: 40,
            child: Center(
              child: badge != null
                  // Collapsed there is no room for a count beside the label,
                  // so it rides on the icon instead of disappearing.
                  ? Badge.count(
                      count: badge!,
                      backgroundColor: selected
                          ? Colors.white.withValues(alpha: 0.22)
                          : p.critical,
                      textColor: Colors.white,
                      child: icon,
                    )
                  : icon,
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: 11,
            ),
            child: Row(
              children: [
                icon,
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
                if (badge != null) _Badge(count: badge!, selected: selected),
              ],
            ),
          );

    final tile = Padding(
      padding: EdgeInsets.only(bottom: collapsed ? 2 : Insets.xs),
      child: Semantics(
        selected: selected,
        button: true,
        // Collapsed, the icon is the only thing on screen, so the label has to
        // come from somewhere for a screen reader.
        label: collapsed ? item.label : null,
        child: Material(
          color: selected ? p.sidebarActive : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.control),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.control),
            hoverColor: Colors.white.withValues(alpha: 0.06),
            focusColor: Colors.white.withValues(alpha: 0.12),
            child: content,
          ),
        ),
      ),
    );

    // Hovering is the only way to read a destination's name when the rail is
    // collapsed, so the tooltip is not decoration — it is the label.
    return collapsed
        ? Tooltip(
            message: item.label,
            waitDuration: Durations.fast,
            child: tile,
          )
        : tile;
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
