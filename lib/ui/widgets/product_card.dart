import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../models/item.dart';
import 'filter_chips.dart';
import 'status_chip.dart';

/// A product tile: photo (or initials) banner, name, mono SKU, category tag,
/// and a Price / Stock / Value figure row.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.item,
    required this.currency,
    required this.categoryColor,
    required this.onTap,
    this.onAdjust,
    this.onMenu,
  });

  final Item item;
  final String currency;
  final Color categoryColor;
  final VoidCallback onTap;
  final void Function(int delta)? onAdjust;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bytes = item.photoBytes;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Banner(item: item, bytes: bytes, onMenu: onMenu),
              Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.sku.isEmpty ? 'No SKU' : item.sku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: p.inkMuted,
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                      ),
                    ),
                    const SizedBox(height: Insets.md),
                    CategoryTag(
                      label: item.category.isEmpty
                          ? 'Uncategorised'
                          : item.category,
                      color: categoryColor,
                    ),
                    const SizedBox(height: Insets.lg),
                    _FigureRow(item: item, currency: currency),
                    if (onAdjust != null) ...[
                      const SizedBox(height: Insets.md),
                      _QuickAdjust(item: item, onAdjust: onAdjust!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.item,
    required this.bytes,
    required this.onMenu,
  });

  final Item item;
  final Uint8List? bytes;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final status = item.status;

    // Out-of-stock and low items tint their banner, so the state is visible in
    // the grid without opening the item.
    final wash = switch (status) {
      StockStatus.out => p.criticalWash,
      StockStatus.low => p.warningWash,
      StockStatus.ok => p.surfaceSunken,
    };

    return SizedBox(
      height: 132,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true)
          else
            ColoredBox(
              color: wash,
              child: Center(
                child: Text(
                  initials(item.name),
                  style: TextStyle(
                    fontFamily: fontDisplay,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: p.inkMuted,
                  ),
                ),
              ),
            ),
          if (status != StockStatus.ok)
            Positioned(
              left: Insets.md,
              bottom: Insets.md,
              child: StatusChip(status: status, compact: true),
            ),
          if (onMenu != null)
            Positioned(
              right: Insets.sm,
              top: Insets.sm,
              child: Material(
                color: p.surface.withValues(alpha: 0.92),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: onMenu,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: p.inkSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FigureRow extends StatelessWidget {
  const _FigureRow({required this.item, required this.currency});

  final Item item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    Widget figure(
      String label,
      String value, {
      Color? valueColor,
      int flex = 1,
    }) {
      return Expanded(
        flex: flex,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11.5, color: p.inkMuted)),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? p.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        figure('Price', money(item.unitCost, currency), flex: 4),
        const SizedBox(width: Insets.sm),
        figure(
          'Stock',
          number(item.quantity),
          valueColor: item.status == StockStatus.out ? p.critical : null,
          flex: 3,
        ),
        const SizedBox(width: Insets.sm),
        figure('Value', money(item.stockValue, currency), flex: 4),
      ],
    );
  }
}

class _QuickAdjust extends StatelessWidget {
  const _QuickAdjust({required this.item, required this.onAdjust});

  final Item item;
  final void Function(int delta) onAdjust;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    Widget button(IconData icon, String tooltip, VoidCallback? onTap) {
      return Expanded(
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: p.surfaceSunken,
            borderRadius: BorderRadius.circular(Radii.control),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.control),
              child: SizedBox(
                height: 34,
                child: Icon(
                  icon,
                  size: 18,
                  color: onTap == null
                      ? p.inkMuted.withValues(alpha: 0.4)
                      : p.inkSecondary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        button(
          Icons.remove,
          'Remove one ${item.name}',
          item.quantity <= 0 ? null : () => onAdjust(-1),
        ),
        const SizedBox(width: Insets.sm),
        button(Icons.add, 'Add one ${item.name}', () => onAdjust(1)),
      ],
    );
  }
}
