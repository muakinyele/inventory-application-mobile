import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

/// What a message is telling you, which picks its icon, colour and heading.
///
/// Tone is never the only signal: every message ships an icon and a heading
/// alongside the colour, so it still reads in greyscale.
enum MessageTone {
  /// The thing you asked for happened.
  success,

  /// Nothing went wrong, but there is something worth knowing.
  info,

  /// The action stopped short of what was asked, or needs something first.
  warning,

  /// The action could not be carried out at all.
  failure,
}

extension _ToneStyle on MessageTone {
  String get heading => switch (this) {
    MessageTone.success => 'Done',
    MessageTone.info => 'Note',
    MessageTone.warning => 'Heads up',
    MessageTone.failure => 'That did not work',
  };

  IconData get icon => switch (this) {
    MessageTone.success => Icons.check_circle_rounded,
    MessageTone.info => Icons.info_rounded,
    MessageTone.warning => Icons.warning_amber_rounded,
    MessageTone.failure => Icons.error_rounded,
  };

  Color colour(Palette p) => switch (this) {
    MessageTone.success => p.good,
    MessageTone.info => p.info,
    MessageTone.warning => p.warning,
    MessageTone.failure => p.critical,
  };

  Color wash(Palette p) => switch (this) {
    MessageTone.success => p.goodWash,
    MessageTone.info => p.infoWash,
    MessageTone.warning => p.warningWash,
    MessageTone.failure => p.criticalWash,
  };
}

/// A second button offered beside the dismiss button — the one thing you might
/// want to do about the message, such as undoing what it just reported.
class MessageAction {
  const MessageAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// Reports [message] in a modal, and completes once it has been dismissed.
///
/// Every outcome the app reports — saved, exported, refused, failed — goes
/// through here, so a message is always in the same place with the same
/// shape. A modal rather than a bar along the bottom: these say whether the
/// thing you just asked for actually happened, and that is worth stopping for
/// rather than something to catch before it slides away.
///
/// Await it before navigating. A dialog is attached to the page it was opened
/// over, so routing away while it is up takes it down with the page.
Future<void> showAppMessage(
  BuildContext context,
  String message, {
  MessageTone tone = MessageTone.success,
  String? title,
  MessageAction? action,
  String dismissLabel = 'OK',
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _MessageDialog(
      message: message,
      tone: tone,
      title: title ?? tone.heading,
      action: action,
      dismissLabel: dismissLabel,
    ),
  );
}

class _MessageDialog extends StatelessWidget {
  const _MessageDialog({
    required this.message,
    required this.tone,
    required this.title,
    required this.action,
    required this.dismissLabel,
  });

  final String message;
  final MessageTone tone;
  final String title;
  final MessageAction? action;
  final String dismissLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = tone.colour(p);
    final action = this.action;

    return AlertDialog(
      // The icon carries the tone, so the title stays a plain heading.
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tone.wash(p),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Icon(tone.icon, size: 20, color: colour),
          ),
          const SizedBox(width: Insets.md),
          Expanded(child: Text(title)),
        ],
      ),
      // Bounded so the dialog stays a dialog on a wide window rather than
      // stretching a one-line message across it.
      content: SizedBox(
        width: 380,
        child: Text(
          message,
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
      ),
      actions: [
        if (action != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              action.onPressed();
            },
            child: Text(action.label),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(dismissLabel),
        ),
      ],
    );
  }
}
