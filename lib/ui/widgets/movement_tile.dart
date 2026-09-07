import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../models/movement.dart';

class MovementTile extends StatelessWidget {
  const MovementTile({
    super.key,
    required this.movement,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.showBalance = false,
  });

  final Movement movement;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool showBalance;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final delta = movement.delta;

    // A transfer leaves the total alone, so it is read off the kind rather
    // than the delta — otherwise it would look like a plain metadata edit.
    final (icon, iconColor, iconWash) = movement.kind == MovementKind.transfer
        ? (Icons.swap_horiz_rounded, p.info, p.infoWash)
        : switch (delta) {
            > 0 => (Icons.arrow_upward, p.goodText, p.goodWash),
            < 0 => (Icons.arrow_downward, p.critical, p.criticalWash),
            _ => (Icons.edit_outlined, p.inkSecondary, p.surfaceSunken),
          };

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconWash,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 16, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: p.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (delta != 0)
                  Text(
                    signed(delta),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: delta > 0 ? p.goodText : p.critical,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                if (showBalance)
                  Text(
                    number(movement.after),
                    style: TextStyle(
                      fontSize: 11,
                      color: p.inkMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
