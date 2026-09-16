import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';

/// A row in the suppliers or customers list. Both are the same shape — a name,
/// some way to reach them, and a couple of facts — so they share one card
/// rather than two near-identical ones.
class ContactCard extends StatelessWidget {
  const ContactCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.facts,
    required this.onEdit,
    required this.onArchive,
    this.badge,
    this.onTap,
  });

  final String name;
  final String subtitle;

  /// Short label/value pairs shown along the bottom.
  final List<(String, String)> facts;

  final Widget? badge;
  final VoidCallback? onTap;
  final VoidCallback onEdit;

  /// Archiving, not deleting: documents reference these, and the
  /// references have to stay resolvable.
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.card),
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: p.accentWash,
                        borderRadius: BorderRadius.circular(Radii.tile),
                      ),
                      child: Center(
                        child: Text(
                          initials(name),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: p.accent,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: p.ink,
                                  ),
                                ),
                              ),
                              if (badge != null) ...[
                                const SizedBox(width: Insets.sm),
                                badge!,
                              ],
                            ],
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: p.inkMuted),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: 'Edit $name',
                    ),
                    IconButton(
                      onPressed: onArchive,
                      icon: const Icon(Icons.archive_outlined, size: 20),
                      tooltip: 'Archive $name',
                      style: IconButton.styleFrom(
                        foregroundColor: p.inkSecondary,
                      ),
                    ),
                  ],
                ),
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: Insets.md),
                  Wrap(
                    spacing: Insets.xxl,
                    runSpacing: Insets.sm,
                    children: [
                      for (final (label, value) in facts)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: p.inkMuted,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              value.isEmpty ? '—' : value,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: p.ink,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small labelled pill, used for a customer's price tier.
class TierBadge extends StatelessWidget {
  const TierBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: p.inkSecondary,
        ),
      ),
    );
  }
}
