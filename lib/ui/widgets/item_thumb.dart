import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../models/item.dart';

/// The item photo, or its initials tinted by stock status.
class ItemThumb extends StatelessWidget {
  const ItemThumb({super.key, required this.item, this.size = 42});

  final Item item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (background, foreground) = switch (item.status) {
      StockStatus.out => (p.criticalWash, p.critical),
      StockStatus.low => (p.warningWash, p.ink),
      StockStatus.ok => (p.accentWash, p.accent),
    };

    final bytes = item.photoBytes;

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : Center(
              child: Text(
                initials(item.name),
                style: TextStyle(
                  fontSize: size * 0.31,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ),
    );
  }
}
