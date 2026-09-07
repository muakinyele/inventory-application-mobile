import 'package:flutter/material.dart';

/// Colour tokens for the whole app, one set per mode.
///
/// Every value is checked against the surface it actually renders on. Two
/// deliberate departures from the visual reference:
///
///  * the sidebar's active pill is stepped down from `#12A5A0` to `#0B7C79`,
///    which lifts its white label from 3.04:1 to 5.03:1;
///  * status colour is never the only signal — it always ships beside an icon
///    and a label, so meaning survives colour-blindness and greyscale.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.plane,
    required this.surface,
    required this.surfaceSunken,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.brand,
    required this.sidebar,
    required this.sidebarRaised,
    required this.sidebarLine,
    required this.sidebarInk,
    required this.sidebarInkMuted,
    required this.sidebarActive,
    required this.good,
    required this.goodText,
    required this.goodWash,
    required this.warning,
    required this.warningText,
    required this.warningWash,
    required this.critical,
    required this.criticalWash,
    required this.info,
    required this.infoWash,
  });

  /// The page canvas behind the cards.
  final Color plane;

  /// Card and panel fill.
  final Color surface;

  /// Recessed fill: tracks, thumbnails, unselected chips.
  final Color surfaceSunken;

  final Color ink;
  final Color inkSecondary;
  final Color inkMuted;
  final Color line;
  final Color lineStrong;

  /// Primary interactive colour — buttons, links, selected chips, focus rings.
  final Color accent;
  final Color accentInk;
  final Color accentWash;

  /// The teal identity colour: logo tile and sidebar selection.
  final Color brand;

  final Color sidebar;
  final Color sidebarRaised;
  final Color sidebarLine;
  final Color sidebarInk;
  final Color sidebarInkMuted;
  final Color sidebarActive;

  final Color good;
  final Color goodText;
  final Color goodWash;
  final Color warning;

  /// Amber is sub-3:1 on light surfaces, so warning *text* uses this darker
  /// step while the amber itself stays on the icon and the wash.
  final Color warningText;
  final Color warningWash;

  final Color critical;
  final Color criticalWash;
  final Color info;
  final Color infoWash;

  static const light = Palette(
    plane: Color(0xFFF3F7FA),
    surface: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF1F5F9),
    ink: Color(0xFF0B1220),
    inkSecondary: Color(0xFF475569),
    inkMuted: Color(0xFF64748B),
    line: Color(0xFFE2E8F0),
    lineStrong: Color(0xFFCBD5E1),
    accent: Color(0xFF10529E),
    accentInk: Color(0xFFFFFFFF),
    accentWash: Color(0x1410529E),
    brand: Color(0xFF0B7C79),
    sidebar: Color(0xFF0B1220),
    sidebarRaised: Color(0xFF121B2C),
    sidebarLine: Color(0x1FFFFFFF),
    sidebarInk: Color(0xFFE2E8F0),
    sidebarInkMuted: Color(0xFF94A3B8),
    sidebarActive: Color(0xFF0B7C79),
    good: Color(0xFF16A34A),
    goodText: Color(0xFF15803D),
    goodWash: Color(0xFFDCFCE7),
    warning: Color(0xFFF5B301),
    warningText: Color(0xFFB45309),
    warningWash: Color(0xFFFEF6E7),
    critical: Color(0xFFDC2626),
    criticalWash: Color(0xFFFEF2F2),
    info: Color(0xFF2563EB),
    infoWash: Color(0xFFEFF6FF),
  );

  static const dark = Palette(
    plane: Color(0xFF0A0F1A),
    surface: Color(0xFF141B2B),
    surfaceSunken: Color(0xFF1D2637),
    ink: Color(0xFFF8FAFC),
    inkSecondary: Color(0xFFCBD5E1),
    inkMuted: Color(0xFF94A3B8),
    line: Color(0xFF253044),
    lineStrong: Color(0xFF3A465C),
    accent: Color(0xFF5B9BF0),
    accentInk: Color(0xFF06121F),
    accentWash: Color(0x285B9BF0),
    brand: Color(0xFF2DD4BF),
    sidebar: Color(0xFF070C16),
    sidebarRaised: Color(0xFF101827),
    sidebarLine: Color(0x1AFFFFFF),
    sidebarInk: Color(0xFFE2E8F0),
    sidebarInkMuted: Color(0xFF94A3B8),
    sidebarActive: Color(0xFF0F8F8B),
    good: Color(0xFF22C55E),
    goodText: Color(0xFF4ADE80),
    goodWash: Color(0x2622C55E),
    warning: Color(0xFFFBBF24),
    warningText: Color(0xFFFBBF24),
    warningWash: Color(0x26FBBF24),
    critical: Color(0xFFF87171),
    criticalWash: Color(0x26F87171),
    info: Color(0xFF60A5FA),
    infoWash: Color(0x2660A5FA),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) {
    if (other is! Palette) return this;
    return t < 0.5 ? this : other;
  }
}

extension PaletteAccess on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}
