import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../models/purchase_order.dart';
import '../../models/sales_order.dart';

/// The coloured state chip on a document. Like the stock badges, it always
/// carries its label, so the state never rests on colour alone.
class PurchaseStatusPill extends StatelessWidget {
  const PurchaseStatusPill({
    super.key,
    required this.status,
    this.overdue = false,
  });

  final PurchaseStatus status;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (color, wash) = switch (status) {
      PurchaseStatus.draft => (p.inkSecondary, p.surfaceSunken),
      PurchaseStatus.ordered => (p.info, p.infoWash),
      PurchaseStatus.partial => (p.warningText, p.warningWash),
      PurchaseStatus.received => (p.goodText, p.goodWash),
      PurchaseStatus.cancelled => (p.critical, p.criticalWash),
    };

    final icon = switch (status) {
      PurchaseStatus.draft => Icons.edit_note_rounded,
      PurchaseStatus.ordered => Icons.schedule_rounded,
      PurchaseStatus.partial => Icons.incomplete_circle_rounded,
      PurchaseStatus.received => Icons.check_circle_outline,
      PurchaseStatus.cancelled => Icons.block_rounded,
    };

    return _Pill(
      icon: icon,
      color: color,
      wash: wash,
      label: status.label,
      overdue: overdue,
    );
  }
}

/// The same chip for a sales document. Kept beside its buying twin so the two
/// document types read identically at a glance.
class SalesStatusPill extends StatelessWidget {
  const SalesStatusPill({
    super.key,
    required this.status,
    this.overdue = false,
  });

  final SalesStatus status;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (color, wash) = switch (status) {
      SalesStatus.draft => (p.inkSecondary, p.surfaceSunken),
      SalesStatus.confirmed => (p.info, p.infoWash),
      SalesStatus.partial => (p.warningText, p.warningWash),
      SalesStatus.fulfilled => (p.goodText, p.goodWash),
      SalesStatus.cancelled => (p.critical, p.criticalWash),
    };

    final icon = switch (status) {
      SalesStatus.draft => Icons.edit_note_rounded,
      SalesStatus.confirmed => Icons.schedule_rounded,
      SalesStatus.partial => Icons.incomplete_circle_rounded,
      SalesStatus.fulfilled => Icons.check_circle_outline,
      SalesStatus.cancelled => Icons.block_rounded,
    };

    return _Pill(
      icon: icon,
      color: color,
      wash: wash,
      label: status.label,
      overdue: overdue,
      overdueLabel: 'Late',
    );
  }
}

/// The chip itself, shared by both document types.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.color,
    required this.wash,
    required this.label,
    this.overdue = false,
    this.overdueLabel = 'Overdue',
  });

  final IconData icon;
  final Color color;
  final Color wash;
  final String label;
  final bool overdue;
  final String overdueLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Chip(icon: icon, color: color, wash: wash, label: label),
        if (overdue) ...[
          const SizedBox(width: Insets.sm),
          _Chip(
            icon: Icons.priority_high_rounded,
            color: p.critical,
            wash: p.criticalWash,
            label: overdueLabel,
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.color,
    required this.wash,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final Color wash;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
