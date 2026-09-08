import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import 'receipt_document.dart' show loadReportFonts;
import 'sales_report.dart';
import 'xlsx_writer.dart';

/// Turns a [SalesReport] into the two things a business actually does with
/// one: a PDF to file or send, and a spreadsheet to work in.
///
/// Both carry the same figures in the same order, so a printed copy and the
/// workbook behind it never disagree.
class ReportDocument {
  const ReportDocument(this.report, this.settings);

  final SalesReport report;
  final AppSettings settings;

  static final _stamp = DateFormat('d MMM yyyy, HH:mm');
  static final _fileStamp = DateFormat('yyyyMMdd');

  String filename(String extension) {
    final from = _fileStamp.format(report.range.start);
    final to = _fileStamp.format(report.range.lastDay);
    final span = from == to ? from : '$from-$to';
    return 'sales-report-$span.$extension';
  }

  String _money(num value) => money(value, report.currency);

  String get _marginText => report.marginRate == null
      ? '—'
      : '${(report.marginRate! * 100).toStringAsFixed(1)}%';

  // --- PDF -------------------------------------------------------------------

  Future<Uint8List> toPdf() async {
    final (regular, semiBold, bold) = await loadReportFonts();
    final doc = pw.Document(
      title: 'Sales report · ${report.range.label}',
      author: settings.companyName,
      subject: 'Revenue, cost of goods and margin',
      creator: 'Stockpile',
    );

    doc.addPage(
      pw.MultiPage(
        // Landscape: the per-item table is six columns of figures, and
        // portrait squeezes the item name down to nothing.
        pageFormat: PdfPageFormat.a4.landscape.copyWith(
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
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 10),
                child: pw.Text(
                  'Sales report · ${report.range.label} (continued)',
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.grey600,
                  ),
                ),
              ),
        footer: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Generated ${_stamp.format(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (context) => [
          _heading(bold, semiBold),
          pw.SizedBox(height: 16),
          _summary(semiBold, bold),
          pw.SizedBox(height: 16),
          if (report.revenueBySource.isNotEmpty) ...[
            _sources(semiBold),
            pw.SizedBox(height: 16),
          ],
          pw.Text('Per item', style: pw.TextStyle(font: bold, fontSize: 12)),
          pw.SizedBox(height: 6),
          _itemTable(semiBold, bold),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _heading(pw.Font bold, pw.Font semiBold) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                settings.companyName,
                style: pw.TextStyle(font: bold, fontSize: 17),
              ),
              if (settings.companyAddress.trim().isNotEmpty)
                pw.Text(
                  settings.companyAddress,
                  style: const pw.TextStyle(
                    fontSize: 9.5,
                    color: PdfColors.grey700,
                  ),
                ),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'SALES REPORT',
              style: pw.TextStyle(font: bold, fontSize: 17),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              report.range.label,
              style: pw.TextStyle(font: semiBold, fontSize: 11),
            ),
            pw.Text(
              '${report.documentCount} '
              '${report.documentCount == 1 ? 'sale' : 'sales'}',
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

  pw.Widget _summary(pw.Font semiBold, pw.Font bold) {
    final tiles = <(String, String, PdfColor?)>[
      ('Revenue', _money(report.revenue), null),
      ('Cost of goods', _money(report.costOfGoods), null),
      (
        'Gross profit',
        _money(report.grossProfit),
        report.grossProfit < 0 ? PdfColors.red800 : PdfColors.green800,
      ),
      (
        'Profit margin',
        _marginText,
        (report.marginRate ?? 0) < 0 ? PdfColors.red800 : PdfColors.green800,
      ),
      ('Units sold', number(report.unitsSold), null),
      if (report.outstanding > 0)
        ('Outstanding', _money(report.outstanding), PdfColors.orange800),
    ];

    return pw.Row(
      children: [
        for (final (label, value, color) in tiles)
          pw.Expanded(
            child: pw.Container(
              margin: const pw.EdgeInsets.only(right: 8),
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: pw.BorderRadius.circular(6),
              ),
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
                  pw.SizedBox(height: 3),
                  pw.Text(
                    value,
                    style: pw.TextStyle(font: bold, fontSize: 12, color: color),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  pw.Widget _sources(pw.Font semiBold) {
    return pw.Row(
      children: [
        for (final source in SaleSource.values)
          if ((report.revenueBySource[source] ?? 0) != 0)
            pw.Padding(
              padding: const pw.EdgeInsets.only(right: 22),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(
                      text: '${source.label}: ',
                      style: const pw.TextStyle(
                        fontSize: 9.5,
                        color: PdfColors.grey700,
                      ),
                    ),
                    pw.TextSpan(
                      text: _money(report.revenueBySource[source] ?? 0),
                      style: pw.TextStyle(font: semiBold, fontSize: 9.5),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  pw.Widget _itemTable(pw.Font semiBold, pw.Font bold) {
    pw.Widget cell(
      String text, {
      pw.Font? font,
      bool right = false,
      PdfColor? color,
      double size = 9.5,
    }) => pw.Container(
      alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: pw.Text(
        text,
        style: pw.TextStyle(font: font, fontSize: size, color: color),
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
        1: pw.FlexColumnWidth(1.6),
        2: pw.FlexColumnWidth(1.2),
        3: pw.FlexColumnWidth(2),
        4: pw.FlexColumnWidth(2),
        5: pw.FlexColumnWidth(2),
        6: pw.FlexColumnWidth(1.4),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            cell('ITEM', font: semiBold, size: 8),
            cell('SKU', font: semiBold, size: 8),
            cell('UNITS', font: semiBold, size: 8, right: true),
            cell('REVENUE', font: semiBold, size: 8, right: true),
            cell('COST OF GOODS', font: semiBold, size: 8, right: true),
            cell('GROSS PROFIT', font: semiBold, size: 8, right: true),
            cell('MARGIN', font: semiBold, size: 8, right: true),
          ],
        ),
        for (final line in report.lines)
          pw.TableRow(
            children: [
              cell(line.itemName),
              cell(line.sku),
              cell(number(line.unitsSold), right: true),
              cell(_money(line.revenue), right: true),
              cell(_money(line.costOfGoods), right: true),
              cell(
                _money(line.grossProfit),
                right: true,
                color: line.grossProfit < 0 ? PdfColors.red800 : null,
              ),
              cell(
                line.marginRate == null
                    ? '—'
                    : '${(line.marginRate! * 100).toStringAsFixed(1)}%',
                right: true,
                color: (line.marginRate ?? 0) < 0 ? PdfColors.red800 : null,
              ),
            ],
          ),
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            cell('TOTAL', font: bold),
            cell(''),
            cell(number(report.unitsSold), font: bold, right: true),
            cell(_money(report.revenue), font: bold, right: true),
            cell(_money(report.costOfGoods), font: bold, right: true),
            cell(_money(report.grossProfit), font: bold, right: true),
            cell(_marginText, font: bold, right: true),
          ],
        ),
      ],
    );
  }

  // --- Excel -----------------------------------------------------------------

  /// Two sheets: the figures to work with, and the assumptions behind them.
  ///
  /// Money goes in as numbers rather than pre-formatted strings — the point of
  /// a spreadsheet is that the columns can be totalled, sorted and charted,
  /// which text in a currency format cannot be.
  Uint8List toXlsx() {
    final summary = Sheet(
      'Sales report',
      columnWidths: [34, 14, 11, 16, 16, 16, 11],
    );

    summary
      ..add([Cell.heading(settings.companyName)])
      ..add([const Cell.text('Sales report'), Cell.text(report.range.label)])
      ..add([
        const Cell.text('Generated'),
        Cell.date(DateTime.now()),
        const Cell.text('Currency'),
        Cell.text(report.currency),
      ])
      ..addBlank()
      ..add([const Cell.heading('Summary')])
      ..add([const Cell.text('Revenue'), Cell.money(report.revenue)])
      ..add([const Cell.text('Cost of goods'), Cell.money(report.costOfGoods)])
      ..add([const Cell.text('Gross profit'), Cell.money(report.grossProfit)])
      ..add([
        const Cell.text('Profit margin'),
        if (report.marginRate != null)
          Cell.percent(report.marginRate!)
        else
          const Cell.text('—'),
      ])
      ..add([const Cell.text('Units sold'), Cell.integer(report.unitsSold)])
      ..add([const Cell.text('Sales'), Cell.integer(report.documentCount)])
      ..add([const Cell.text('Credit sales'), Cell.integer(report.creditSales)])
      ..add([const Cell.text('Outstanding'), Cell.money(report.outstanding)])
      ..addBlank()
      ..add([const Cell.heading('Revenue by source')]);

    for (final source in SaleSource.values) {
      final value = report.revenueBySource[source] ?? 0;
      if (value == 0) continue;
      summary.add([Cell.text(source.label), Cell.money(value)]);
    }

    summary
      ..addBlank()
      ..add([const Cell.heading('Per item')])
      ..add([
        const Cell.heading('Item'),
        const Cell.heading('SKU'),
        const Cell.heading('Units'),
        const Cell.heading('Revenue'),
        const Cell.heading('Cost of goods'),
        const Cell.heading('Gross profit'),
        const Cell.heading('Margin'),
      ]);

    for (final line in report.lines) {
      summary.add([
        Cell.text(line.itemName),
        Cell.text(line.sku),
        Cell.integer(line.unitsSold),
        Cell.money(line.revenue),
        Cell.money(line.costOfGoods),
        Cell.money(line.grossProfit),
        if (line.marginRate != null)
          Cell.percent(line.marginRate!)
        else
          const Cell.text('—'),
      ]);
    }

    summary.add([
      const Cell.heading('Total'),
      Cell.blank,
      Cell.integer(report.unitsSold),
      Cell.money(report.revenue),
      Cell.money(report.costOfGoods),
      Cell.money(report.grossProfit),
      if (report.marginRate != null)
        Cell.percent(report.marginRate!)
      else
        const Cell.text('—'),
    ]);

    // A reader who sorts the table and gets a different total deserves to
    // know why, so the rules travel with the numbers.
    final notes = Sheet('Basis', columnWidths: [18, 96])
      ..add([const Cell.heading('How these figures are counted')])
      ..addBlank()
      ..add([
        const Cell.text('Period'),
        Cell.text(
          '${report.range.label}. Covers sales from '
          '${DateFormat('d MMM yyyy').format(report.range.start)} to '
          '${DateFormat('d MMM yyyy').format(report.range.lastDay)} inclusive.',
        ),
      ])
      ..add([
        const Cell.text('Revenue'),
        const Cell.text(
          'Recognised when the goods leave the shelf, not when the money '
          'arrives, and stated after discounts and before tax. Tax is '
          'collected on the government\'s behalf and is not income.',
        ),
      ])
      ..add([
        const Cell.text('Counted once'),
        const Cell.text(
          'A sale is counted at the document that moved the stock: a counter '
          'receipt, a credit invoice, or a despatch against a sales order. '
          'Paperwork raised on top — a receipt for an invoice payment, an '
          'invoice billing a sales order — moves no stock and is excluded, so '
          'nothing is counted twice.',
        ),
      ])
      ..add([
        const Cell.text('Credit sales'),
        const Cell.text(
          'Counted in full on the day they were invoiced. Any part not yet '
          'collected is shown as Outstanding rather than deducted from '
          'revenue.',
        ),
      ])
      ..add([
        const Cell.text('Cost of goods'),
        const Cell.text(
          'The weighted-average cost of the stock at the moment it left, '
          'banked on the document. Later changes to an item\'s cost do not '
          'rewrite a sale that has already happened.',
        ),
      ])
      ..add([
        const Cell.text('Refunds'),
        const Cell.text(
          'Netted off the item they were returned against, in both units and '
          'revenue. Voided documents are excluded entirely.',
        ),
      ])
      ..add([
        const Cell.text('Sales orders'),
        const Cell.text(
          'Despatches are not individually dated, so an order is recognised '
          'on the date it was confirmed. An order confirmed and sent in the '
          'same period is exact.',
        ),
      ]);

    return buildXlsx([summary, notes]);
  }
}
