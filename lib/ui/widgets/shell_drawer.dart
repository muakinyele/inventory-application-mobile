import 'package:flutter/material.dart';

/// A way to open the shell's navigation drawer from inside a page.
///
/// EVERY PAGE BUILDS ITS OWN `Scaffold`, and the drawer belongs to the shell's,
/// further up the tree. So the menu button's `Scaffold.of(context).openDrawer`
/// found the PAGE's Scaffold — which has no drawer — and `openDrawer()` on one
/// of those is a silent no-op. The button rendered, took the tap, and did
/// nothing, on every screen.
///
/// Published by the shell rather than reached for with a `GlobalKey` so that
/// a page with no shell above it — a widget test, a document view opened on its
/// own — gets null and can leave the button out, instead of drawing one that
/// cannot work.
class ShellDrawer extends InheritedWidget {
  const ShellDrawer({super.key, required this.open, required super.child});

  /// Opens the drawer. Resolved against the shell's own Scaffold.
  final VoidCallback open;

  /// The opener, or null when there is no shell above [context].
  static VoidCallback? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellDrawer>()?.open;

  @override
  bool updateShouldNotify(ShellDrawer oldWidget) => oldWidget.open != open;
}
