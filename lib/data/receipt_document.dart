import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/receipt.dart';

Future<(pw.Font, pw.Font, pw.Font)>? _fontsFuture;

/// Regular, semi-bold and bold Inter, for anything this app renders to PDF.
///
/// Inter is embedded rather than using a built-in PDF face because the base-14
/// fonts are WinAnsi-only and cannot render "₦" — which would silently drop
/// the currency symbol from every total on a Nigerian document.
///
/// Cached: parsing three TTFs is the slow part of producing a PDF, and a
/// report and a receipt want exactly the same three.
Future<(pw.Font, pw.Font, pw.Font)> loadReportFonts() {
  return _fontsFuture ??= () async {
    Future<pw.Font> load(String name) async =>
        pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));
    return (
      await load('Inter-Regular'),
      await load('Inter-SemiBold'),
      await load('Inter-Bold'),
    );
  }();
}

/// Turns a receipt into the files a customer or an accountant can be handed.
///
/// The document is built from what is stored on the receipt itself — its own
/// tax rate, its own prices, its own totals — never from current settings, so
/// re-printing a receipt from last year reproduces it exactly rather than
/// re-charging it at today's rate. The only thing settings supply is the
/// letterhead.
class ReceiptDocument {
  const ReceiptDocument(this.receipt, this.settings);

  final Receipt receipt;
  final AppSettings settings;

  static final _stamp = DateFormat('d MMM yyyy, HH:mm');
  static final _fileStamp = DateFormat('yyyyMMdd');

  /// A filename that sorts by date and says what it is.
  String filename(String extension) =>
      '${receipt.reference}-${_fileStamp.format(receipt.issuedAt)}.$extension';

  String get _currency => settings.currency;

  String _money(num value) => money(value, _currency);

  // --- PDF -----------------------------------------------------------------

  /// A4 by default. Pass [roll] for an 80mm till-roll page, which is what a
  /// thermal printer wants.
  Future<Uint8List> toPdf({bool roll = false}) async {
    final (regular, semiBold, bold) = await loadReportFonts();
    final theme = pw.ThemeData.withFont(
      base: regular,
      bold: bold,
      italic: regular,
      boldItalic: bold,
    );

    final doc = pw.Document(
      title: '${receipt.reference} · ${settings.companyName}',
      author: settings.companyName,
      subject: 'Receipt ${receipt.reference}',
      creator: 'Stockpile',
    );

    if (roll) {
      // A till roll is one continuous strip, not a sequence of pages, so it
      // is built as a single Page whose height grows to fit — which is also
      // why it cannot be a MultiPage, as those need a page height to break
      // against and reject an unbounded one.
      doc.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(
            80 * PdfPageFormat.mm,
            double.infinity,
            marginAll: 6 * PdfPageFormat.mm,
          ),
          theme: theme,
          build: (context) => pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: _rollBody(semiBold, bold),
          ),
        ),
      );
      return doc.save();
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginTop: 28,
          marginBottom: 28,
          marginLeft: 32,
          marginRight: 32,
        ),
        theme: theme,
        build: (context) => _sheetBody(context, semiBold, bold),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 12),
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
      ),
    );

    return doc.save();
  }

  // --- A4 layout -----------------------------------------------------------

  List<pw.Widget> _sheetBody(
    pw.Context context,
    pw.Font semiBold,
    pw.Font bold,
  ) {
    return [
      _letterhead(bold, semiBold),
      pw.SizedBox(height: 20),
      _parties(semiBold),
      pw.SizedBox(height: 16),
      _linesTable(semiBold),
      pw.SizedBox(height: 12),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: _notesBlock(semiBold)),
          pw.SizedBox(width: 24),
          pw.SizedBox(width: 240, child: _totals(semiBold, bold)),
        ],
      ),
      if (receipt.status == ReceiptStatus.voided) ...[
        pw.SizedBox(height: 18),
        _voidBanner(bold),
      ],
      pw.SizedBox(height: 24),
      pw.Divider(color: PdfColors.grey300, height: 1),
      pw.SizedBox(height: 8),
      pw.Text(
        settings.receiptFooter,
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ),
    ];
  }

  pw.Widget _letterhead(pw.Font bold, pw.Font semiBold) {
    final contact = [
      settings.companyAddress,
      settings.companyPhone,
      settings.companyEmail,
    ].where((line) => line.trim().isNotEmpty).toList();

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                settings.companyName,
                style: pw.TextStyle(font: bold, fontSize: 18),
              ),
              for (final line in contact)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2),
                  child: pw.Text(
                    line,
                    style: const pw.TextStyle(
                      fontSize: 9.5,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text('RECEIPT', style: pw.TextStyle(font: bold, fontSize: 20)),
            pw.SizedBox(height: 2),
            pw.Text(
              receipt.reference,
              style: pw.TextStyle(font: semiBold, fontSize: 12),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              _stamp.format(receipt.issuedAt),
              style: const pw.TextStyle(
                fontSize: 9.5,
                color: PdfColors.grey700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  pw.Widget _parties(pw.Font semiBold) {
    final facts = <(String, String)>[
      (
        'Billed to',
        receipt.customerName.isEmpty
            ? 'Walk-in customer'
            : receipt.customerName,
      ),
      ('Payment', receipt.method.label),
      ('Status', receipt.status.label),
      if (receipt.salesOrderId != null) ('Against sale', 'See order'),
      if (receipt.cashier.isNotEmpty) ('Served by', receipt.cashier),
    ];

    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Row(
        children: [
          for (final (label, value) in facts)
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    label.toUpperCase(),
                    style: const pw.TextStyle(
                      fontSize: 7.5,
                      color: PdfColors.grey600,
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    value,
                    style: pw.TextStyle(font: semiBold, fontSize: 10),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  pw.Widget _linesTable(pw.Font semiBold) {
    final showDiscount = receipt.lineDiscount > 0;
    final showRefunds = receipt.unitsRefunded > 0;

    pw.Widget cell(
      String text, {
      bool head = false,
      pw.Alignment align = pw.Alignment.centerLeft,
    }) => pw.Container(
      alignment: align,
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: pw.Text(
        text,
        style: head
            ? pw.TextStyle(
                font: semiBold,
                fontSize: 8,
                color: PdfColors.grey700,
              )
            : const pw.TextStyle(fontSize: 9.5),
      ),
    );

    return pw.Table(
      border: pw.TableBorder(
        horizontalInside: const pw.BorderSide(
          color: PdfColors.grey300,
          width: 0.5,
        ),
        bottom: const pw.BorderSide(color: PdfColors.grey400, width: 0.5),
        top: const pw.BorderSide(color: PdfColors.grey400, width: 0.5),
      ),
      columnWidths: {
        0: const pw.FlexColumnWidth(4),
        1: const pw.FlexColumnWidth(1.2),
        2: const pw.FlexColumnWidth(1.8),
        if (showDiscount) 3: const pw.FlexColumnWidth(1.6),
        (showDiscount ? 4 : 3): const pw.FlexColumnWidth(1.9),
      },
      children: [
        pw.TableRow(
          children: [
            cell('ITEM', head: true),
            cell('QTY', head: true, align: pw.Alignment.centerRight),
            cell('PRICE', head: true, align: pw.Alignment.centerRight),
            if (showDiscount)
              cell('DISCOUNT', head: true, align: pw.Alignment.centerRight),
            cell('AMOUNT', head: true, align: pw.Alignment.centerRight),
          ],
        ),
        for (final line in receipt.lines)
          pw.TableRow(
            children: [
              cell(
                [
                  line.itemName,
                  if (line.sku.isNotEmpty) '(${line.sku})',
                  if (showRefunds && line.quantityRefunded > 0)
                    '— ${number(line.quantityRefunded)} returned',
                ].join(' '),
              ),
              cell(
                '${number(line.quantity)} ${line.unit}',
                align: pw.Alignment.centerRight,
              ),
              cell(_money(line.unitPrice), align: pw.Alignment.centerRight),
              if (showDiscount)
                cell(
                  line.discount > 0 ? '-${_money(line.discount)}' : '—',
                  align: pw.Alignment.centerRight,
                ),
              cell(_money(line.net), align: pw.Alignment.centerRight),
            ],
          ),
      ],
    );
  }

  pw.Widget _totals(pw.Font semiBold, pw.Font bold) {
    pw.Widget row(
      String label,
      String value, {
      bool strong = false,
      PdfColor? color,
    }) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              font: strong ? bold : null,
              fontSize: strong ? 11 : 9.5,
              color: color ?? (strong ? null : PdfColors.grey700),
            ),
          ),
          pw.Text(
            value,
            style: pw.TextStyle(
              font: strong ? bold : semiBold,
              fontSize: strong ? 11 : 9.5,
              color: color,
            ),
          ),
        ],
      ),
    );

    final taxPercent = (receipt.taxRate * 100).toStringAsFixed(
      receipt.taxRate * 100 % 1 == 0 ? 0 : 2,
    );

    return pw.Column(
      children: [
        row('Subtotal', _money(receipt.gross)),
        if (receipt.discountTotal > 0)
          row('Discount', '-${_money(receipt.discountTotal)}'),
        if (receipt.taxRate > 0)
          row('${receipt.taxLabel} ($taxPercent%)', _money(receipt.tax)),
        pw.Divider(color: PdfColors.grey400, height: 10),
        row('Total', _money(receipt.total), strong: true),
        row('Paid (${receipt.method.label})', _money(receipt.amountPaid)),
        if (receipt.change > 0) row('Change', _money(receipt.change)),
        if (receipt.balanceDue > 0)
          row(
            'Balance due',
            _money(receipt.balanceDue),
            color: PdfColors.red800,
          ),
        if (receipt.refundTotal > 0) ...[
          pw.Divider(color: PdfColors.grey400, height: 10),
          row('Refunded', '-${_money(receipt.refundTotal)}'),
          row('Net total', _money(receipt.netTotal), strong: true),
        ],
      ],
    );
  }

  pw.Widget _notesBlock(pw.Font semiBold) {
    if (receipt.notes.isEmpty) return pw.SizedBox();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'NOTES',
          style: pw.TextStyle(
            font: semiBold,
            fontSize: 7.5,
            color: PdfColors.grey600,
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          receipt.notes,
          style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800),
        ),
      ],
    );
  }

  pw.Widget _voidBanner(pw.Font bold) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.red50,
        border: pw.Border.all(color: PdfColors.red200),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Text(
        receipt.voidReason.isEmpty
            ? 'THIS RECEIPT HAS BEEN VOIDED'
            : 'THIS RECEIPT HAS BEEN VOIDED — ${receipt.voidReason}',
        style: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.red800),
      ),
    );
  }

  // --- 80mm till roll ------------------------------------------------------

  List<pw.Widget> _rollBody(pw.Font semiBold, pw.Font bold) {
    pw.Widget centred(String text, {pw.Font? font, double size = 8.5}) =>
        pw.Container(
          width: double.infinity,
          alignment: pw.Alignment.center,
          child: pw.Text(
            text,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: font, fontSize: size),
          ),
        );

    pw.Widget pair(String label, String value, {pw.Font? font}) => pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: pw.TextStyle(font: font, fontSize: 8.5)),
        pw.Text(value, style: pw.TextStyle(font: font, fontSize: 8.5)),
      ],
    );

    final rule = pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Divider(color: PdfColors.grey500, height: 1),
    );

    return [
      centred(settings.companyName, font: bold, size: 11),
      for (final line in [
        settings.companyAddress,
        settings.companyPhone,
      ].where((l) => l.trim().isNotEmpty))
        centred(line, size: 7.5),
      rule,
      pair('Receipt', receipt.reference, font: semiBold),
      pair('Date', _stamp.format(receipt.issuedAt)),
      pair(
        'Customer',
        receipt.customerName.isEmpty ? 'Walk-in' : receipt.customerName,
      ),
      rule,
      for (final line in receipt.lines) ...[
        pw.Text(
          line.itemName,
          style: pw.TextStyle(font: semiBold, fontSize: 8.5),
        ),
        pair(
          '  ${number(line.quantity)} x ${_money(line.unitPrice)}',
          _money(line.net),
        ),
      ],
      rule,
      pair('Subtotal', _money(receipt.gross)),
      if (receipt.discountTotal > 0)
        pair('Discount', '-${_money(receipt.discountTotal)}'),
      if (receipt.taxRate > 0) pair(receipt.taxLabel, _money(receipt.tax)),
      pair('TOTAL', _money(receipt.total), font: bold),
      pair(receipt.method.label, _money(receipt.amountPaid)),
      if (receipt.change > 0) pair('Change', _money(receipt.change)),
      if (receipt.balanceDue > 0)
        pair('Balance due', _money(receipt.balanceDue)),
      if (receipt.status == ReceiptStatus.voided) ...[
        rule,
        centred('*** VOIDED ***', font: bold, size: 10),
      ],
      rule,
      centred(settings.receiptFooter, size: 7.5),
    ];
  }

  // --- Text formats --------------------------------------------------------

  /// A 40-column plain-text receipt — what a thermal printer or an SMS wants,
  /// and readable anywhere a PDF is overkill.
  String toPlainText({int width = 40}) {
    final out = StringBuffer();

    // A footer line or an address is easily longer than the roll is wide, so
    // anything oversized is folded onto the next line rather than run off the
    // edge — which on a real till printer is simply lost.
    void centre(String text) {
      for (final line in _wrap(text, width)) {
        final pad = ((width - line.length) / 2).floor();
        out.writeln(' ' * (pad < 0 ? 0 : pad) + line);
      }
    }

    void pair(String label, String value) {
      final gap = width - label.length - value.length;
      out.writeln(label + ' ' * (gap < 1 ? 1 : gap) + value);
    }

    void rule([String ch = '-']) => out.writeln(ch * width);

    centre(settings.companyName);
    for (final line in [
      settings.companyAddress,
      settings.companyPhone,
      settings.companyEmail,
    ].where((l) => l.trim().isNotEmpty)) {
      centre(line);
    }
    rule('=');
    pair('Receipt', receipt.reference);
    pair('Date', _stamp.format(receipt.issuedAt));
    pair(
      'Customer',
      receipt.customerName.isEmpty ? 'Walk-in' : receipt.customerName,
    );
    if (receipt.cashier.isNotEmpty) pair('Served by', receipt.cashier);
    rule();

    for (final line in receipt.lines) {
      for (final part in _wrap(line.itemName, width)) {
        out.writeln(part);
      }
      pair(
        '  ${number(line.quantity)} ${line.unit} x ${_money(line.unitPrice)}',
        _money(line.net),
      );
      if (line.discount > 0) pair('  Discount', '-${_money(line.discount)}');
      if (line.quantityRefunded > 0) {
        pair('  Returned', '${number(line.quantityRefunded)} ${line.unit}');
      }
    }

    rule();
    pair('Subtotal', _money(receipt.gross));
    if (receipt.discountTotal > 0) {
      pair('Discount', '-${_money(receipt.discountTotal)}');
    }
    if (receipt.taxRate > 0) {
      pair(receipt.taxLabel, _money(receipt.tax));
    }
    rule('=');
    pair('TOTAL', _money(receipt.total));
    pair('Paid (${receipt.method.label})', _money(receipt.amountPaid));
    if (receipt.change > 0) pair('Change', _money(receipt.change));
    if (receipt.balanceDue > 0) pair('Balance due', _money(receipt.balanceDue));
    if (receipt.refundTotal > 0) {
      pair('Refunded', '-${_money(receipt.refundTotal)}');
      pair('Net total', _money(receipt.netTotal));
    }
    if (receipt.status == ReceiptStatus.voided) {
      rule();
      centre('*** VOIDED ***');
      if (receipt.voidReason.isNotEmpty) centre(receipt.voidReason);
    }
    if (receipt.notes.isNotEmpty) {
      rule();
      for (final line in _wrap(receipt.notes, width)) {
        out.writeln(line);
      }
    }
    rule('=');
    centre(settings.receiptFooter);

    return out.toString();
  }

  /// One row per line, with the receipt's identity repeated on each — the
  /// shape a spreadsheet or an accounts package expects to be fed.
  String toCsv() => receiptsToCsv([receipt], settings);

  String toJson() =>
      const JsonEncoder.withIndent('  ').convert(receipt.toJson());
}

/// Folds [text] to [width] on word boundaries. A single word longer than the
/// line — a long SKU, a URL — is cut rather than allowed to overhang, since
/// the whole point of the fixed width is that nothing falls off the paper.
List<String> _wrap(String text, int width) {
  if (width <= 0) return [text];
  final lines = <String>[];
  for (final paragraph in text.split('\n')) {
    var current = '';
    for (final word in paragraph.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      if (current.isEmpty) {
        current = word;
      } else if (current.length + 1 + word.length <= width) {
        current = '$current $word';
      } else {
        lines.add(current);
        current = word;
      }
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
    }
    lines.add(current);
  }
  return lines;
}

const _receiptColumns = [
  'reference',
  'issuedAt',
  'status',
  'customer',
  'paymentMethod',
  'item',
  'sku',
  'quantity',
  'unit',
  'unitPrice',
  'lineDiscount',
  'lineTotal',
  'quantityRefunded',
  'receiptSubtotal',
  'receiptDiscount',
  'taxLabel',
  'taxRate',
  'tax',
  'receiptTotal',
  'amountPaid',
  'change',
  'balanceDue',
  'refunded',
  'netTotal',
  'notes',
];

String _escape(Object? value) {
  final s = value?.toString() ?? '';
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// A flat sheet of receipt lines. Money is written unformatted so the figures
/// stay arithmetic rather than text a spreadsheet has to be talked out of.
String receiptsToCsv(List<Receipt> receipts, AppSettings settings) {
  final rows = <String>[];
  for (final r in receipts) {
    // A receipt with no lines still gets a row, so a voided or empty document
    // never silently vanishes from the export.
    final lines = r.lines.isEmpty ? [null] : r.lines;
    for (final line in lines) {
      rows.add(
        <Object?>[
          r.reference,
          r.issuedAt.toIso8601String(),
          r.status.name,
          r.customerName,
          r.method.name,
          line?.itemName ?? '',
          line?.sku ?? '',
          line?.quantity ?? 0,
          line?.unit ?? '',
          line?.unitPrice ?? 0,
          line?.discount ?? 0,
          line?.net ?? 0,
          line?.quantityRefunded ?? 0,
          r.subtotal,
          r.discountTotal,
          r.taxLabel,
          r.taxRate,
          r.tax,
          r.total,
          r.amountPaid,
          r.change,
          r.balanceDue,
          r.refundTotal,
          r.netTotal,
          r.notes,
        ].map(_escape).join(','),
      );
    }
  }
  return [_receiptColumns.join(','), ...rows].join('\n');
}

/// The whole receipt book, in full fidelity — the format to re-import from.
String receiptsToJson(List<Receipt> receipts, AppSettings settings) {
  return const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'exportedAt': DateTime.now().toIso8601String(),
    'company': settings.companyName,
    'currency': settings.currency,
    'receipts': [for (final r in receipts) r.toJson()],
  });
}
