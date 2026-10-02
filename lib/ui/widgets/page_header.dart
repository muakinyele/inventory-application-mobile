import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import 'shell_drawer.dart';

/// The standard page top: an optional back or menu affordance, a large bold
/// title with optional subtitle, and right-aligned actions that wrap under the
/// title when the window is too narrow to hold them on one line.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.showBack = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebar;

    // Null when the sidebar is already on screen, or when there is no shell
    // above this page — a widget test, a document opened on its own.
    final openDrawer = wide ? null : ShellDrawer.of(context);

    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showBack)
          Padding(
            padding: const EdgeInsets.only(right: Insets.xs),
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
              style: IconButton.styleFrom(foregroundColor: p.ink),
            ),
          )
        // Only when there is a drawer to open. A menu button that cannot
        // open anything is worse than no button: it takes the tap and does
        // nothing, which is exactly what it did before.
        else if (openDrawer != null)
          Padding(
            padding: const EdgeInsets.only(right: Insets.xs),
            child: IconButton(
              onPressed: openDrawer,
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Open navigation',
              style: IconButton.styleFrom(foregroundColor: p.ink),
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(fontSize: wide ? 30 : 25),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: p.inkMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (actions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Insets.xl),
        child: heading,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below this the title plus a row of buttons collide, so the actions
          // drop to their own line instead of squeezing the title away.
          final inline = constraints.maxWidth >= 640;
          if (inline) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: heading),
                const SizedBox(width: Insets.lg),
                Wrap(spacing: Insets.sm, children: actions),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: Insets.md),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: actions,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Page body scaffolding: consistent gutters that widen beside the sidebar.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.controller});

  final List<Widget> children;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebar;
    final gutter = wide ? Insets.pageWide : Insets.pageNarrow;

    return ListView(
      controller: controller,
      padding: EdgeInsets.fromLTRB(gutter, Insets.xl, gutter, Insets.section),
      children: children,
    );
  }
}
