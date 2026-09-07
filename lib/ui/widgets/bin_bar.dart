import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../models/transfer.dart';

/// One location's share of a stock total, as a labelled bar.
///
/// Used both for a single item's split across bins and for the whole
/// catalogue's split, so the two read identically. Magnitude of one measure,
/// so it is one hue rather than a colour per location — and the figure is
/// always spelled out beside the bar, never left to the bar alone.
class BinBar extends StatelessWidget {
  const BinBar({
    super.key,
    required this.location,
    required this.quantity,
    required this.total,
    this.trailing,
    this.badge,
  });

  final String location;
  final int quantity;
  final int total;

  /// Text on the right, defaulting to the quantity.
  final String? trailing;

  /// A small chip after the name, such as "Home".
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final share = total <= 0 ? 0.0 : quantity / total;
    final unassigned = location == unassignedLocation;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: unassigned ? p.warningText : p.ink,
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: p.surfaceSunken,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: p.inkSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          flex: 4,
          child: LayoutBuilder(
            builder: (context, constraints) => Container(
              height: 6,
              decoration: BoxDecoration(
                color: p.surfaceSunken,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: constraints.maxWidth * share,
                  decoration: BoxDecoration(
                    color: unassigned ? p.warningText : p.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: Insets.md),
        SizedBox(
          width: 86,
          child: Text(
            trailing ?? number(quantity),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
