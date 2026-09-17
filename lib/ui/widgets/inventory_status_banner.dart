import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../state/inventory_controller.dart';

/// Says when the shared catalogue could not be read, or when a stock write was
/// refused because somebody else had already moved the count.
///
/// Both of those were silent until now. A failed load left the screen looking
/// like a workspace nobody had put anything in yet, and a refused write looked
/// exactly like nothing happening — which is the worse of the two, because the
/// user has a number in their head and no reason to doubt it.
///
/// Shown as a strip above the page rather than a dialogue: neither needs
/// dismissing before work can continue, and a modal over a list the user is
/// mid-way through reading is its own annoyance.
class InventoryStatusBanner extends StatelessWidget {
  const InventoryStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InventoryController>();

    final conflict = controller.stockConflict;
    if (conflict != null) {
      return _Strip(
        icon: Icons.sync_problem_rounded,
        tone: context.palette.warning,
        message: conflict,
        // Nothing to retry: the count on screen is the server's, and repeating
        // the change would apply it against a number the user never saw. They
        // decide what to do now they can see the real figure.
        action: null,
      );
    }

    return switch (controller.load) {
      InventoryLoad.failed => _Strip(
        icon: Icons.cloud_off_rounded,
        tone: context.palette.critical,
        message:
            'The inventory could not be loaded. What is on screen may be out '
            'of date.',
        action: (label: 'Try again', onPressed: controller.reload),
      ),
      InventoryLoad.loading => _Strip(
        icon: Icons.cloud_sync_rounded,
        tone: context.palette.inkSecondary,
        message: 'Loading the inventory…',
        action: null,
      ),
      InventoryLoad.idle || InventoryLoad.ready => const SizedBox.shrink(),
    };
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.icon,
    required this.tone,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final Color tone;
  final String message;
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Material(
      color: tone.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tone),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 13.5, height: 1.35, color: tone),
              ),
            ),
            if (action != null)
              TextButton(
                onPressed: action.onPressed,
                child: Text(action.label),
              ),
          ],
        ),
      ),
    );
  }
}
