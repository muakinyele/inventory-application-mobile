import 'package:flutter/material.dart';

import 'design.dart';
import 'palette.dart';

/// Inter's text optical size: spaced for small UI sizes, and the source of the
/// tabular figures the tables and charts rely on.
const fontBody = 'Inter';

/// Inter's display optical size: tighter apertures and spacing, which only
/// look right above roughly 20px. Reserved for page and figure headings.
const fontDisplay = 'InterDisplay';

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(brightness: brightness);

  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: brightness,
      ).copyWith(
        primary: p.accent,
        onPrimary: p.accentInk,
        surface: p.surface,
        onSurface: p.ink,
        error: p.critical,
        outline: p.line,
      );

  final text = base.textTheme
      .apply(fontFamily: fontBody, bodyColor: p.ink, displayColor: p.ink)
      .copyWith(
        // Page titles: heavy and tight, set in the display optical size.
        headlineMedium: TextStyle(
          fontFamily: fontDisplay,
          fontSize: 30,
          height: 1.15,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.9,
          color: p.ink,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
        titleSmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
        bodyMedium: TextStyle(fontSize: 14, color: p.ink),
        bodySmall: TextStyle(fontSize: 13, color: p.inkSecondary),
        labelMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.inkSecondary,
        ),
        labelSmall: TextStyle(fontSize: 12, color: p.inkMuted),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.plane,
    canvasColor: p.plane,
    extensions: [p],
    fontFamily: fontBody,
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,

    appBarTheme: AppBarTheme(
      backgroundColor: p.plane,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.headlineMedium,
    ),

    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: p.line),
      ),
    ),

    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.accentInk,
        disabledBackgroundColor: p.surfaceSunken,
        disabledForegroundColor: p.inkMuted,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: p.surface,
        disabledForegroundColor: p.inkMuted,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        side: BorderSide(color: p.lineStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.inkSecondary,
        minimumSize: const Size(0, 40),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.inkSecondary),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(color: p.inkMuted, fontSize: 14.5),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.md,
      ),
      border: _border(p.lineStrong),
      enabledBorder: _border(p.lineStrong),
      focusedBorder: _border(p.accent, width: 2),
      errorBorder: _border(p.critical),
      focusedErrorBorder: _border(p.critical, width: 2),
      disabledBorder: _border(p.line),
      labelStyle: TextStyle(color: p.inkSecondary, fontSize: 14),
      floatingLabelStyle: TextStyle(color: p.accent, fontSize: 14),
      helperStyle: TextStyle(color: p.inkMuted, fontSize: 12),
      errorStyle: TextStyle(color: p.critical, fontSize: 12),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentWash,
      height: 66,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? p.accent : p.inkMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? p.accent : p.inkMuted,
        ),
      ),
    ),

    drawerTheme: DrawerThemeData(
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.lineStrong,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
      contentTextStyle: TextStyle(fontSize: 14, color: p.inkSecondary),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: TextStyle(color: p.plane, fontSize: 13.5),
      actionTextColor: p.plane,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.control),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceSunken,
      selectedColor: p.accent,
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: 6),
      labelStyle: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: p.inkSecondary,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: p.accentInk,
      ),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),

    listTileTheme: ListTileThemeData(
      iconColor: p.inkSecondary,
      textColor: p.ink,
      contentPadding: EdgeInsets.zero,
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.ink,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: p.plane, fontSize: 12),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.surfaceSunken,
    ),
  );
}

OutlineInputBorder _border(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.control),
    borderSide: BorderSide(color: color, width: width),
  );
}
