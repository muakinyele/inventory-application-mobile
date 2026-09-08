import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

/// A titled surface panel — the unit every screen is built from.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(Insets.xl),
  });

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    title!,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: p.ink,
                    ),
                  ),
                ),
                // Capped rather than free: a caption long enough to fill the
                // row used to push the title to zero width, which wrapped it
                // one letter per line and overflowed the card. Loose fit, so
                // a short caption still takes only what it needs.
                if (trailing != null) ...[
                  const SizedBox(width: Insets.sm),
                  Flexible(flex: 2, child: trailing!),
                ],
              ],
            ),
            const SizedBox(height: Insets.md),
          ],
          child,
        ],
      ),
    );
  }
}
