import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../models/item.dart';

/// Stock state always ships as colour **plus** an icon and a label, so the
/// meaning survives colour-blindness, greyscale printing and forced-colours.
class StatusStyle {
  const StatusStyle(this.label, this.icon, this.color, this.wash);
  final String label;
  final IconData icon;
  final Color color;
  final Color wash;
}

StatusStyle statusStyle(BuildContext context, StockStatus status) {
  final p = context.palette;
  switch (status) {
    case StockStatus.out:
      return StatusStyle(
        'Out of stock',
        Icons.error_outline,
        p.critical,
        p.criticalWash,
      );
    case StockStatus.low:
      return StatusStyle(
        'Low stock',
        Icons.warning_amber_rounded,
        p.warningText,
        p.warningWash,
      );
    case StockStatus.ok:
      return StatusStyle(
        'In stock',
        Icons.check_circle_outline,
        p.goodText,
        p.goodWash,
      );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.compact = false});

  final StockStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = statusStyle(context, status);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: 3),
      decoration: BoxDecoration(
        color: style.wash,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: compact ? 12 : 14, color: style.color),
          const SizedBox(width: 4),
          Text(
            style.label,
            style: TextStyle(
              fontSize: compact ? 10.5 : 11.5,
              fontWeight: FontWeight.w700,
              color: style.color,
            ),
          ),
        ],
      ),
    );
  }
}
