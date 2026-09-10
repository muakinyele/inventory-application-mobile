import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

/// The frame every signed-out screen sits in.
///
/// One card, centred, on the same pale canvas the rest of the app uses, with
/// the same surface, hairline border and radius as [SectionCard]. The point is
/// that sign-in looks like the product rather than like a separate login
/// product bolted on the front (§2, §24).
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.footer,
    this.icon = Icons.inventory_2_rounded,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? footer;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.pageNarrow,
              vertical: Insets.section,
            ),
            child: ConstrainedBox(
              // Wide enough for a comfortable field, narrow enough that the
              // eye does not have to travel on a desktop monitor.
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Brand(icon: icon),
                  const SizedBox(height: Insets.xxl),
                  Container(
                    padding: const EdgeInsets.all(Insets.section),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(Radii.card),
                      border: Border.all(color: p.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: Insets.sm),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              color: p.inkSecondary,
                              height: 1.5,
                            ),
                          ),
                        ],
                        const SizedBox(height: Insets.xxl),
                        child,
                      ],
                    ),
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: Insets.xl),
                    DefaultTextStyle.merge(
                      style: TextStyle(color: p.inkSecondary, fontSize: 13),
                      textAlign: TextAlign.center,
                      child: footer!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: p.accent,
            borderRadius: BorderRadius.circular(Radii.tile),
          ),
          child: Icon(icon, color: p.accentInk, size: 28),
        ),
        const SizedBox(height: Insets.md),
        Text(
          'Stockpile',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(letterSpacing: -0.2),
        ),
      ],
    );
  }
}

/// The inline error banner the auth forms use.
///
/// A banner rather than a modal: on a sign-in form the message belongs beside
/// the fields you are about to correct, not behind a dialog you have to
/// dismiss before you can retype anything.
class AuthNotice extends StatelessWidget {
  const AuthNotice({
    super.key,
    required this.message,
    this.details = const [],
    this.tone = AuthNoticeTone.failure,
    this.action,
  });

  final String message;
  final List<String> details;
  final AuthNoticeTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (colour, wash, icon) = switch (tone) {
      AuthNoticeTone.failure => (
        p.critical,
        p.criticalWash,
        Icons.error_rounded,
      ),
      AuthNoticeTone.warning => (
        p.warningText,
        p.warningWash,
        Icons.warning_amber_rounded,
      ),
      AuthNoticeTone.info => (p.info, p.infoWash, Icons.info_rounded),
      AuthNoticeTone.success => (
        p.goodText,
        p.goodWash,
        Icons.check_circle_rounded,
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: colour.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Colour is never the only signal: every tone carries its own icon.
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(
                    color: colour,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  for (final detail in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '• $detail',
                        style: TextStyle(color: colour, height: 1.4),
                      ),
                    ),
                ],
                if (action != null) ...[
                  const SizedBox(height: Insets.xs),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum AuthNoticeTone { failure, warning, info, success }
