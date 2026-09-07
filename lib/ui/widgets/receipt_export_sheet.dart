import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/export_service.dart';
import '../../data/receipt_document.dart';
import '../../models/app_settings.dart';
import '../../models/receipt.dart';

/// The formats a receipt can leave the app in.
enum ReceiptFormat { pdf, roll, text, csv, json }

extension ReceiptFormatDetail on ReceiptFormat {
  String get label => switch (this) {
    ReceiptFormat.pdf => 'PDF document',
    ReceiptFormat.roll => 'PDF till roll (80mm)',
    ReceiptFormat.text => 'Plain text',
    ReceiptFormat.csv => 'Spreadsheet (CSV)',
    ReceiptFormat.json => 'Data file (JSON)',
  };

  String get note => switch (this) {
    ReceiptFormat.pdf => 'A4 — the one to email or file',
    ReceiptFormat.roll => 'Sized for a counter printer',
    ReceiptFormat.text => '40 columns, prints anywhere',
    ReceiptFormat.csv => 'One row per line, for the books',
    ReceiptFormat.json => 'Every field, for another system',
  };

  IconData get icon => switch (this) {
    ReceiptFormat.pdf => Icons.picture_as_pdf_outlined,
    ReceiptFormat.roll => Icons.receipt_long_outlined,
    ReceiptFormat.text => Icons.notes_outlined,
    ReceiptFormat.csv => Icons.table_chart_outlined,
    ReceiptFormat.json => Icons.data_object_outlined,
  };

  String get extension => switch (this) {
    ReceiptFormat.pdf || ReceiptFormat.roll => 'pdf',
    ReceiptFormat.text => 'txt',
    ReceiptFormat.csv => 'csv',
    ReceiptFormat.json => 'json',
  };

  String get mimeType => switch (this) {
    ReceiptFormat.pdf || ReceiptFormat.roll => 'application/pdf',
    ReceiptFormat.text => 'text/plain',
    ReceiptFormat.csv => 'text/csv',
    ReceiptFormat.json => 'application/json',
  };
}

/// Builds one receipt in [format] and hands it to the platform — the share
/// sheet on a phone, a download in the browser.
///
/// Kept separate from the sheet that picks the format so a screen can export
/// straight to PDF without asking, which is what the button on a detail page
/// does.
Future<void> exportReceipt({
  required Receipt receipt,
  required AppSettings settings,
  required ReceiptFormat format,
  Rect? originRect,
}) async {
  final doc = ReceiptDocument(receipt, settings);
  final filename = doc.filename(format.extension);

  if (format == ReceiptFormat.pdf || format == ReceiptFormat.roll) {
    await const ExportService().shareBytes(
      filename: format == ReceiptFormat.roll
          ? doc.filename('roll.pdf')
          : filename,
      bytes: await doc.toPdf(roll: format == ReceiptFormat.roll),
      mimeType: format.mimeType,
      originRect: originRect,
    );
    return;
  }

  await const ExportService().shareText(
    filename: filename,
    contents: switch (format) {
      ReceiptFormat.text => doc.toPlainText(),
      ReceiptFormat.csv => doc.toCsv(),
      ReceiptFormat.json => doc.toJson(),
      _ => '',
    },
    mimeType: format.mimeType,
    originRect: originRect,
  );
}

/// Asks which format, and returns it. Null when the sheet is dismissed.
Future<ReceiptFormat?> pickReceiptFormat(BuildContext context) {
  return showModalBottomSheet<ReceiptFormat>(
    context: context,
    builder: (sheetContext) {
      final p = sheetContext.palette;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xl,
                Insets.md,
                Insets.xl,
                Insets.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Download or share',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pick the format you need.',
                    style: TextStyle(fontSize: 13, color: p.inkSecondary),
                  ),
                ],
              ),
            ),
            for (final format in ReceiptFormat.values)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Insets.xl,
                ),
                leading: Icon(format.icon, color: p.accent),
                title: Text(
                  format.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  format.note,
                  style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                ),
                onTap: () => Navigator.of(sheetContext).pop(format),
              ),
            const SizedBox(height: Insets.sm),
          ],
        ),
      );
    },
  );
}
