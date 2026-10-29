import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/invoice.dart';
import '../models/receipt.dart';
import 'receipt_document.dart'
    show bankDetailsBlock, companyLogoBlock, loadReportFonts;

/// Renders an invoice as the document a customer is sent.
///
/// Deliberately the receipt's twin in layout, because they are the same sale
/// seen at two moments. Where a receipt says what was paid, an invoice says
/// what is owed and by when — so the money block leads with the balance and
/// the page carries the payment terms.
class InvoiceDocument {
  const InvoiceDocument(
    this.invoice,
    this.settings, {
    this.payments = const [],
  });

  final Invoice invoice;
  final AppSettings settings;

  /// Payments taken so far, listed so the customer can see how the balance
  /// was arrived at rather than having to trust it.
  final List<InvoicePayment> payments;

  static final _stamp = DateFormat('d MMM yyyy');
  static final _fileStamp = DateFormat('yyyyMMdd');

  String filename(String extension) =>
      '${invoice.reference}-${_fileStamp.format(invoice.issuedAt)}.$extension';

  String _money(num value) => money(value, settings.currency);

  Future<Uint8List> toPdf() async {
    final (regular, semiBold, bold) = await loadReportFonts();
    final doc = pw.Document(
      title: '${invoice.reference} · ${settings.companyName}',
      author: settings.companyName,
      subject: 'Invoice ${invoice.reference}',
      creator: 'Stockpile',
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginTop: 28,
          marginBottom: 28,
          marginLeft: 32,
          marginRight: 32,
        ),
        theme: pw.ThemeData.withFont(
          base: regular,
          bold: bold,
          italic: regular,
          boldItalic: bold,
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 12),
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          _letterhead(bold, semiBold),
          pw.SizedBox(height: 20),
          _parties(semiBold),
          pw.SizedBox(height: 16),
          _lineTable(semiBold),
          pw.SizedBox(height: 12),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(child: _notes(semiBold)),
              pw.SizedBox(width: 24),
              pw.SizedBox(width: 250, child: _totals(semiBold, bold)),
            ],
          ),
          if (invoice.status == InvoiceStatus.cancelled) ...[
            pw.SizedBox(height: 18),
            _cancelledBanner(bold),
          ],
          pw.SizedBox(height: 24),
          pw.Divider(color: PdfColors.grey300, height: 1),
          pw.SizedBox(height: 8),
          pw.Text(
            settings.receiptFooter,
            style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _letterhead(pw.Font bold, pw.Font semiBold) {
    final contact = [
      settings.companyAddress,
      settings.companyPhone,
      settings.companyEmail,
    ].where((l) => l.trim().isNotEmpty).toList();

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              companyLogoBlock(settings),
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
            pw.Text('INVOICE', style: pw.TextStyle(font: bold, fontSize: 20)),
            pw.SizedBox(height: 2),
            pw.Text(
              invoice.reference,
              style: pw.TextStyle(font: semiBold, fontSize: 12),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Issued ${_stamp.format(invoice.issuedAt)}',
              style: const pw.TextStyle(
                fontSize: 9.5,
                color: PdfColors.grey700,
              ),
            ),
            if (invoice.dueAt != null)
              pw.Text(
                'Due ${_stamp.format(invoice.dueAt!)}',
                style: pw.TextStyle(
                  font: semiBold,
                  fontSize: 9.5,
                  color: invoice.isOverdue
                      ? PdfColors.red800
                      : PdfColors.grey800,
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
        invoice.customerName.isEmpty
            ? 'Account customer'
            : invoice.customerName,
      ),
      ('Status', invoice.status.label),
      if (invoice.terms.isNotEmpty) ('Terms', invoice.terms),
      ('Balance due', _money(invoice.balanceDue)),
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

  pw.Widget _lineTable(pw.Font semiBold) {
    final showDiscount = invoice.lineDiscount > 0;

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
        top: const pw.BorderSide(color: PdfColors.grey400, width: 0.5),
        bottom: const pw.BorderSide(color: PdfColors.grey400, width: 0.5),
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
        for (final line in invoice.lines)
          pw.TableRow(
            children: [
              cell(
                [
                  line.itemName,
                  if (line.sku.isNotEmpty) '(${line.sku})',
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

    final percent = (invoice.taxRate * 100).toStringAsFixed(
      invoice.taxRate * 100 % 1 == 0 ? 0 : 2,
    );

    return pw.Column(
      children: [
        row('Subtotal', _money(invoice.gross)),
        if (invoice.discountTotal > 0)
          row('Discount', '-${_money(invoice.discountTotal)}'),
        if (invoice.taxRate > 0)
          row('${invoice.taxLabel} ($percent%)', _money(invoice.tax)),
        pw.Divider(color: PdfColors.grey400, height: 10),
        row('Invoice total', _money(invoice.total), strong: true),
        for (final payment in payments)
          row(
            '${payment.reference} · ${payment.method.label}',
            '-${_money(payment.amount)}',
          ),
        if (invoice.amountPaid > 0 && payments.isEmpty)
          row('Paid', '-${_money(invoice.amountPaid)}'),
        pw.Divider(color: PdfColors.grey400, height: 10),
        row(
          invoice.isSettled ? 'Paid in full' : 'Balance due',
          _money(invoice.balanceDue),
          strong: true,
          color: invoice.isSettled
              ? PdfColors.green800
              : (invoice.isOverdue ? PdfColors.red800 : null),
        ),
      ],
    );
  }

  pw.Widget _notes(pw.Font semiBold) {
    final blocks = <(String, String)>[
      if (invoice.terms.isNotEmpty) ('PAYMENT TERMS', invoice.terms),
      if (invoice.notes.isNotEmpty) ('NOTES', invoice.notes),
    ];
    // Where to pay, while there is something to pay.
    final payInto =
        invoice.status != InvoiceStatus.cancelled && !invoice.isSettled;
    if (blocks.isEmpty && !(payInto && settings.hasBankDetails)) {
      return pw.SizedBox();
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (payInto) bankDetailsBlock(settings, semiBold),
        for (final (label, body) in blocks)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  label,
                  style: pw.TextStyle(
                    font: semiBold,
                    fontSize: 7.5,
                    color: PdfColors.grey600,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  body,
                  style: const pw.TextStyle(
                    fontSize: 9.5,
                    color: PdfColors.grey800,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  pw.Widget _cancelledBanner(pw.Font bold) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.red50,
        border: pw.Border.all(color: PdfColors.red200),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Text(
        invoice.cancelledReason.isEmpty
            ? 'THIS INVOICE HAS BEEN CANCELLED'
            : 'THIS INVOICE HAS BEEN CANCELLED — ${invoice.cancelledReason}',
        style: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.red800),
      ),
    );
  }

  String toJson() =>
      const JsonEncoder.withIndent('  ').convert(invoice.toJson());
}

const _invoiceColumns = [
  'reference',
  'issuedAt',
  'dueAt',
  'status',
  'customer',
  'item',
  'sku',
  'quantity',
  'unit',
  'unitPrice',
  'lineDiscount',
  'lineTotal',
  'invoiceSubtotal',
  'invoiceDiscount',
  'taxLabel',
  'taxRate',
  'tax',
  'invoiceTotal',
  'amountPaid',
  'balanceDue',
  'terms',
  'notes',
];

String _escape(Object? value) {
  final s = value?.toString() ?? '';
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// A flat sheet of invoice lines, for the books.
String invoicesToCsv(List<Invoice> invoices) {
  final rows = <String>[];
  for (final i in invoices) {
    final lines = i.lines.isEmpty ? [null] : i.lines;
    for (final line in lines) {
      rows.add(
        <Object?>[
          i.reference,
          i.issuedAt.toIso8601String(),
          i.dueAt?.toIso8601String() ?? '',
          i.status.name,
          i.customerName,
          line?.itemName ?? '',
          line?.sku ?? '',
          line?.quantity ?? 0,
          line?.unit ?? '',
          line?.unitPrice ?? 0,
          line?.discount ?? 0,
          line?.net ?? 0,
          i.subtotal,
          i.discountTotal,
          i.taxLabel,
          i.taxRate,
          i.tax,
          i.total,
          i.amountPaid,
          i.balanceDue,
          i.terms,
          i.notes,
        ].map(_escape).join(','),
      );
    }
  }
  return [_invoiceColumns.join(','), ...rows].join('\n');
}
