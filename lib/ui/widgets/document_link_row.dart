import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';

/// One paper document listed on another one's page — the receipts against a
/// sale, the invoices raised for it, the receipts that paid an invoice.
///
/// A single row shared by all of them so a cross-reference reads the same
/// wherever it appears, and tapping it always opens the document.
class DocumentLinkRow extends StatelessWidget {
  const DocumentLinkRow({
    super.key,
    required this.reference,
    required this.detail,
    required this.amount,
    required this.onOpen,
  });

  final String reference;
  final String detail;
  final String amount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    reference,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  Text(
                    detail,
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.sm),
            Text(
              amount,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: p.ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: Insets.sm),
            Icon(Icons.chevron_right, size: 18, color: p.inkMuted),
          ],
        ),
      ),
    );
  }
}
