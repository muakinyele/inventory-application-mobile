import 'package:flutter/material.dart';

import '../../data/auth_api.dart';
import '../../state/new_version.dart';
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
    // A newer build comes first: until it is loaded, a fix already deployed
    // is not running in this tab.
    return ValueListenableBuilder<bool>(
      valueListenable: newVersionReady,
      builder: (context, ready, _) => ready
          ? _Strip(
              icon: Icons.system_update_alt_rounded,
              tone: context.palette.accent,
              message:
                  'A new version of Stockpile is ready. Reload to use it; '
                  'anything already saved stays.',
              action: (label: 'Reload', onPressed: reloadToNewVersion),
            )
          : _status(context),
    );
  }

  Widget _status(BuildContext context) {
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

    // A FAILED WRITE, WHICH WAS THE QUIETEST FAILURE OF THE LOT. It sits below
    // a stock conflict, which is about one specific number the user is looking
    // at, and above the load states, which are about the whole screen — but it
    // is shown on every screen because a save can fail from any of them.
    //
    // No retry button: the controller keeps no record of what the failed write
    // was trying to do, so a button here could only pretend. Saying plainly
    // that the change did not reach the server, and leaving the user to do it
    // again, is the honest offer.
    if (controller.lastWriteError != null) {
      return _Strip(
        icon: Icons.cloud_off_rounded,
        tone: context.palette.critical,
        // With the server's reason where it gave one, so the banner says what
        // went wrong rather than only that something did.
        message:
            'The last change could not be saved'
            '${controller.lastWriteError is AuthApiException ? ': ${(controller.lastWriteError as AuthApiException).message}' : ''}. '
            'What is on screen has not reached the server, and will be gone '
            'when this page reloads.',
        action: (label: 'Dismiss', onPressed: controller.clearWriteError),
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
