import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

class FilterOption<T> {
  const FilterOption(this.value, this.label, {this.icon, this.dotColor});
  final T value;
  final String label;
  final IconData? icon;

  /// A category's swatch, shown as a leading dot.
  final Color? dotColor;
}

/// A horizontally scrolling row of pill filters. Selection is a filled accent
/// pill; everything else is a recessed neutral, matching the reference.
class FilterChips<T> extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<FilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: Insets.sm),
        itemBuilder: (context, index) {
          final option = options[index];
          final isSelected = option.value == selected;
          final foreground = isSelected ? p.accentInk : p.inkSecondary;

          return Semantics(
            selected: isSelected,
            button: true,
            child: Material(
              color: isSelected ? p.accent : p.surfaceSunken,
              borderRadius: BorderRadius.circular(Radii.pill),
              child: InkWell(
                onTap: () => onSelected(option.value),
                borderRadius: BorderRadius.circular(Radii.pill),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (option.dotColor != null) ...[
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: option.dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: Insets.sm),
                      ] else if (option.icon != null) ...[
                        Icon(option.icon, size: 16, color: foreground),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        option.label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A small pill showing a category with its swatch, used on product cards.
class CategoryTag extends StatelessWidget {
  const CategoryTag({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 4),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
