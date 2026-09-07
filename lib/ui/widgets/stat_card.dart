import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';

/// The pastel rounded square that carries a stat card's icon.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    this.icon,
    this.glyph,
    required this.color,
    required this.wash,
    this.size = 44,
  }) : assert(
         icon != null || glyph != null,
         'give the tile an icon or a glyph',
       );

  final IconData? icon;

  /// A short piece of text used in place of an icon — a currency symbol, say,
  /// which has no Material icon for most currencies.
  final String? glyph;

  final Color color;
  final Color wash;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: icon != null
          ? Icon(icon, size: size * 0.48, color: color)
          : Center(
              child: Text(
                glyph!,
                maxLines: 1,
                style: TextStyle(
                  fontSize: size * 0.45,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
    );
  }
}

enum StatTone { neutral, info, good, warning, critical }

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    this.icon,
    this.glyph,
    required this.value,
    required this.label,
    this.tone = StatTone.info,
    this.onTap,
  }) : assert(
         icon != null || glyph != null,
         'give the card an icon or a glyph',
       );

  final IconData? icon;

  /// Rendered instead of [icon]; see [IconTile.glyph].
  final String? glyph;
  final String value;
  final String label;
  final StatTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (color, wash) = switch (tone) {
      StatTone.info => (p.info, p.infoWash),
      StatTone.good => (p.goodText, p.goodWash),
      StatTone.warning => (p.warningText, p.warningWash),
      StatTone.critical => (p.critical, p.criticalWash),
      StatTone.neutral => (p.inkSecondary, p.surfaceSunken),
    };

    final card = Container(
      padding: const EdgeInsets.all(Insets.xl),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTile(icon: icon, glyph: glyph, color: color, wash: wash),
          const SizedBox(height: Insets.lg),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontFamily: fontDisplay,
                fontSize: 28,
                height: 1.1,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.9,
                color: p.ink,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, color: p.inkMuted),
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: card,
      ),
    );
  }
}

/// Lays stat cards out 1-, 2- or 4-up depending on the space available.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 900
            ? 4
            : width >= 560
            ? 2
            : width >= 380
            ? 2
            : 1;
        const gap = Insets.md;
        final tileWidth = (width - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: tileWidth, child: card),
          ],
        );
      },
    );
  }
}
