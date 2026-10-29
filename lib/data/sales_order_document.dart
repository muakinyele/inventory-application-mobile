import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/item.dart';
import '../models/party.dart';
import '../models/sales_order.dart';
import 'receipt_document.dart'
    show bankDetailsBlock, companyLogoBlock, loadReportFonts;

/// Renders a sales order as the document a customer is sent.
///
/// Laid out as the invoice's twin, because it is the same sale one step
/// earlier: the same letterhead, logo, contact lines and footer from
/// Settings → Invoices & receipts, the same strip of facts and the same line
/// table. Where an invoice says what is owed, an order says what was agreed
/// and how much of it has gone out.
///
/// Tax is shown at the workspace rate, because that is the rate an invoice
/// raised from this order is billed at — so the total here is the total the
/// customer will be invoiced, not a figure that changes on the next page.
class SalesOrderDocument {
  const SalesOrderDocument(this.order, this.settings, {this.itemById});

  final SalesOrder order;
  final AppSettings settings;

  /// Looks up the catalogue item for a line, for its code and unit. The order
  /// line does not carry either.
  final Item? Function(String itemId)? itemById;

  static final _stamp = DateFormat('d MMM yyyy');
  static final _fileStamp = DateFormat('yyyyMMdd');

  DateTime get _dated => order.confirmedAt ?? order.createdAt;

  String filename(String extension) =>
      '${order.reference}-${_fileStamp.format(_dated)}.$extension';

  String _money(num value) => money(value, settings.currency);

  double get _taxRate => settings.taxRate.clamp(0, 1).toDouble();
  double get _tax => order.total * _taxRate;
  double get _grandTotal => order.total + _tax;

  Future<Uint8List> toPdf() async {
    final (regular, semiBold, bold) = await loadReportFonts();
    final doc = pw.Document(
      title: '${order.reference} · ${settings.companyName}',
      author: settings.companyName,
      subject: 'Sales order ${order.reference}',
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
          if (order.status == SalesStatus.cancelled) ...[
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
            pw.Text(
              'SALES ORDER',
              style: pw.TextStyle(font: bold, fontSize: 20),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              order.reference,
              style: pw.TextStyle(font: semiBold, fontSize: 12),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Dated ${_stamp.format(_dated)}',
              style: const pw.TextStyle(
                fontSize: 9.5,
                color: PdfColors.grey700,
              ),
            ),
            if (order.dueAt != null)
              pw.Text(
                'Due ${_stamp.format(order.dueAt!)}',
                style: pw.TextStyle(
                  font: semiBold,
                  fontSize: 9.5,
                  color: order.isOverdue ? PdfColors.red800 : PdfColors.grey800,
                ),
              ),
          ],
        ),
      ],
    );
  }

  pw.Widget _parties(pw.Font semiBold) {
    final outstanding = order.unitsOutstanding;
    final facts = <(String, String)>[
      ('Customer', order.customerName.isEmpty ? 'Walk-in' : order.customerName),
      ('Status', order.status.label),
      ('Prices', order.priceTier.label),
      (
        'Still to send',
        order.status == SalesStatus.cancelled
            ? '—'
            : outstanding == 0
            ? 'Nothing'
            : '${number(outstanding)} ${outstanding == 1 ? 'unit' : 'units'}',
      ),
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
      columnWidths: const {
        0: pw.FlexColumnWidth(4),
        1: pw.FlexColumnWidth(1.3),
        2: pw.FlexColumnWidth(1.1),
        3: pw.FlexColumnWidth(1.8),
        4: pw.FlexColumnWidth(1.9),
      },
      children: [
        pw.TableRow(
          children: [
            cell('ITEM', head: true),
            cell('QTY', head: true, align: pw.Alignment.centerRight),
            cell('SENT', head: true, align: pw.Alignment.centerRight),
            cell('PRICE', head: true, align: pw.Alignment.centerRight),
            cell('AMOUNT', head: true, align: pw.Alignment.centerRight),
          ],
        ),
        for (final line in order.lines)
          () {
            final item = itemById?.call(line.itemId);
            final sku = item?.sku ?? '';
            final unit = item?.unit ?? '';
            return pw.TableRow(
              children: [
                cell([line.itemName, if (sku.isNotEmpty) '($sku)'].join(' ')),
                cell(
                  [number(line.quantityOrdered), unit].join(' ').trim(),
                  align: pw.Alignment.centerRight,
                ),
                cell(
                  number(line.quantityFulfilled),
                  align: pw.Alignment.centerRight,
                ),
                cell(_money(line.unitPrice), align: pw.Alignment.centerRight),
                cell(_money(line.lineTotal), align: pw.Alignment.centerRight),
              ],
            );
          }(),
      ],
    );
  }

  pw.Widget _totals(pw.Font semiBold, pw.Font bold) {
    pw.Widget row(String label, String value, {bool strong = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                label,
                style: pw.TextStyle(
                  font: strong ? bold : null,
                  fontSize: strong ? 11 : 9.5,
                  color: strong ? null : PdfColors.grey700,
                ),
              ),
              pw.Text(
                value,
                style: pw.TextStyle(
                  font: strong ? bold : semiBold,
                  fontSize: strong ? 11 : 9.5,
                ),
              ),
            ],
          ),
        );

    final percent = (_taxRate * 100).toStringAsFixed(
      _taxRate * 100 % 1 == 0 ? 0 : 2,
    );

    return pw.Column(
      children: [
        row('Subtotal', _money(order.total)),
        if (_taxRate > 0) row('${settings.taxLabel} ($percent%)', _money(_tax)),
        pw.Divider(color: PdfColors.grey400, height: 10),
        row('Order total', _money(_grandTotal), strong: true),
      ],
    );
  }

  pw.Widget _notes(pw.Font semiBold) {
    final payInto = order.status != SalesStatus.cancelled;
    if (order.notes.trim().isEmpty) {
      return payInto ? bankDetailsBlock(settings, semiBold) : pw.SizedBox();
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (payInto) bankDetailsBlock(settings, semiBold),
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
          order.notes.trim(),
          style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800),
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
        'THIS SALES ORDER HAS BEEN CANCELLED',
        style: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.red800),
      ),
    );
  }

  /// The message a WhatsApp, email or text carries: what was ordered and what
  /// it comes to, since none of those can attach the PDF.
  String summary() {
    final lines = [
      '${settings.companyName} — sales order ${order.reference}',
      'Customer: ${order.customerName.isEmpty ? 'Walk-in' : order.customerName}',
      'Status: ${order.status.label}',
      if (order.dueAt != null) 'Due: ${longDate(order.dueAt!)}',
      '',
      for (final line in order.lines)
        '${number(line.quantityOrdered)} × ${line.itemName} — '
            '${_money(line.lineTotal)}',
      '',
      if (_taxRate > 0) ...[
        'Subtotal: ${_money(order.total)}',
        '${settings.taxLabel}: ${_money(_tax)}',
      ],
      'Order total: ${_money(_grandTotal)}',
      if (settings.hasBankDetails && order.status != SalesStatus.cancelled) ...[
        '',
        'Pay into:',
        ...settings.bankLines,
      ],
      if (order.notes.trim().isNotEmpty) ...['', order.notes.trim()],
    ];
    return lines.join('\n');
  }
}
