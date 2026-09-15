import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// Asks before something the user cannot simply undo.
///
/// Returns false when dismissed by tapping outside, so a dialog that never
/// reached a button is a refusal rather than consent.
///
/// [destructive] paints the confirm button in the critical colour. It changes
/// nothing about the behaviour — it is there so that "Delete" and "Save" do
/// not look alike at a glance.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final p = context.palette;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body, style: const TextStyle(height: 1.5)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: p.critical)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
