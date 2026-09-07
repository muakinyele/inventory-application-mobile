/// Layout constants shared by every screen, so spacing and rounding stay on a
/// scale instead of being re-guessed per widget.
abstract final class Insets {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const section = 28.0;

  /// Horizontal page padding: roomier once there is a sidebar beside it.
  static const pageNarrow = 16.0;
  static const pageWide = 28.0;
}

abstract final class Radii {
  static const card = 14.0;
  static const control = 10.0;
  static const tile = 12.0;
  static const pill = 999.0;
}

abstract final class Breakpoints {
  /// At or above this width the shell shows the sidebar instead of tabs.
  static const sidebar = 900.0;

  /// Below this a two-up form row stacks.
  static const formStack = 420.0;

  /// Widest the content column is allowed to grow beside the sidebar.
  static const contentMax = 1280.0;
}

abstract final class Durations {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
}
