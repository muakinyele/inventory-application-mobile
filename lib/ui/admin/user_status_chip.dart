import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../models/auth_user.dart';

/// The account-status badge (§8).
///
/// Follows the app's existing rule for status: colour plus an icon plus a
/// word, so it still reads in greyscale and to anyone who cannot separate the
/// hues.
class UserStatusChip extends StatelessWidget {
  const UserStatusChip({super.key, required this.user});

  final ManagedUser user;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final (colour, wash, icon) = switch (user.statusLabel) {
      'Locked' => (p.warningText, p.warningWash, Icons.lock_clock_rounded),
      'Active' => (p.goodText, p.goodWash, Icons.check_circle_outline_rounded),
      'Pending' => (p.info, p.infoWash, Icons.hourglass_bottom_rounded),
      'Disabled' => (p.critical, p.criticalWash, Icons.block_rounded),
      _ => (p.inkSecondary, p.surfaceSunken, Icons.help_outline_rounded),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: Insets.xs),
          Text(
            user.statusLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: colour,
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the address has been confirmed (§12).
class VerificationChip extends StatelessWidget {
  const VerificationChip({super.key, required this.verified});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = verified ? p.goodText : p.warningText;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          verified ? Icons.verified_rounded : Icons.error_outline_rounded,
          size: 14,
          color: colour,
        ),
        const SizedBox(width: Insets.xs),
        Text(
          verified ? 'Email confirmed' : 'Email not confirmed',
          style: TextStyle(fontSize: 12, color: colour),
        ),
      ],
    );
  }
}
