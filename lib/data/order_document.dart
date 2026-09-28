import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/formatters.dart';
import '../models/app_settings.dart';
import '../models/purchase_order.dart';
import '../models/sales_order.dart';
import 'receipt_document.dart' show companyLogoBlock, loadReportFonts;

/// One line of an order, as the printed document needs it.
class OrderDocumentLine {
  const OrderDocumentLine({
    required this.itemName,
    required this.quantity,
    required this.settled,
    required this.unitPrice,
    required this.lineTotal,
  });

  final String itemName;
  final int quantity;

  /// Received, for a purchase; despatched, for a sale. Printed so the party
  /// reading it can see what is still outstanding without doing the
  /// subtraction.
  final int settled;

  final double unitPrice;
  final double lineTotal;

  int get outstanding => (quantity - settled).clamp(0, quantity);
}

/// A purchase or sales order, flattened to what a document has to say.
///
/// ONE DOCUMENT FOR BOTH, because they are the same page with the nouns
/// swapped: a reference, the other party, what was ordered, what has moved,
/// what it comes to. Writing it twice would mean two layouts drifting apart,
/// and the supplier's copy looking unlike the customer's for no reason anyone
/// chose.
class OrderDocumentData {
  const OrderDocumentData({
    required this.kind,
    required this.reference,
    required this.partyLabel,
    required this.partyName,
    required this.status,
    required this.issuedAt,
    required this.lines,
    required this.total,
    required this.settledLabel,
    this.dueAt,
    this.dueLabel,
    this.overdue = false,
    this.notes = '',
  });

  /// 'PURCHASE ORDER' or 'SALES ORDER', printed at the head.
  final String kind;
  final String reference;

  /// 'Supplier' or 'Customer'.
  final String partyLabel;
  final String partyName;
  final String status;
  final DateTime issuedAt;

  /// 'Expected' for a purchase, 'Due' for a sale.
  final DateTime? dueAt;
  final String? dueLabel;
  final bool overdue;

  /// The column heading for what has moved: 'RECEIVED' or 'SENT'.
  final String settledLabel;

  final List<OrderDocumentLine> lines;
  final double total;
  final String notes;

  factory OrderDocumentData.fromPurchase(PurchaseOrder order) =>
      OrderDocumentData(
        kind: 'PURCHASE ORDER',
        reference: order.reference,
        partyLabel: 'Supplier',
        partyName: order.supplierName.isEmpty
            ? 'Not assigned'
            : order.supplierName,
        status: order.status.label,
        // An order that was never sent has no ordered date; the day it was
        // drafted is the honest thing to print rather than nothing.
        issuedAt: order.orderedAt ?? order.createdAt,
        dueAt: order.expectedAt,
        dueLabel: 'Expected',
        overdue: order.isOverdue,
        settledLabel: 'RECEIVED',
        notes: order.notes,
        total: order.total,
        lines: [
          for (final line in order.lines)
            OrderDocumentLine(
              itemName: line.itemName,
              quantity: line.quantityOrdered,
              settled: line.quantityReceived,
              unitPrice: line.unitCost,
              lineTotal: line.lineTotal,
            ),
        ],
      );

  factory OrderDocumentData.fromSales(SalesOrder order) => OrderDocumentData(
    kind: 'SALES ORDER',
    reference: order.reference,
    partyLabel: 'Customer',
    partyName: order.customerName.isEmpty ? 'Walk-in' : order.customerName,
    status: order.status.label,
    issuedAt: order.confirmedAt ?? order.createdAt,
    dueAt: order.dueAt,
    dueLabel: 'Due',
    settledLabel: 'SENT',
    notes: order.notes,
    total: order.total,
    lines: [
      for (final line in order.lines)
        OrderDocumentLine(
          itemName: line.itemName,
          quantity: line.quantityOrdered,
          settled: line.quantityFulfilled,
          unitPrice: line.unitPrice,
          lineTotal: line.lineTotal,
        ),
    ],
  );
}

/// Renders an order as the document the other party is sent.
///
/// Laid out as the invoice's sibling on purpose: a supplier who receives a
/// purchase order and later an invoice from the same business should not have
/// to work out that they came from the same place.
class OrderDocument {
  const OrderDocument(this.data, this.settings);

  final OrderDocumentData data;
  final AppSettings settings;

  static final _stamp = DateFormat('d MMM yyyy');
  static final _fileStamp = DateFormat('yyyyMMdd');

  String filename(String extension) =>
      '${data.reference}-${_fileStamp.format(data.issuedAt)}.$extension';

  String _money(num value) => money(value, settings.currency);

  Future<Uint8List> toPdf() async {
    final (regular, semiBold, bold) = await loadReportFonts();
    final doc = pw.Document(
      title: '${data.reference} · ${settings.companyName}',
      author: settings.companyName,
      subject: '${data.kind} ${data.reference}',
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
            pw.Text(data.kind, style: pw.TextStyle(font: bold, fontSize: 18)),
            pw.SizedBox(height: 2),
            pw.Text(
              data.reference,
              style: pw.TextStyle(font: semiBold, fontSize: 12),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Raised ${_stamp.format(data.issuedAt)}',
              style: const pw.TextStyle(
                fontSize: 9.5,
                color: PdfColors.grey700,
              ),
            ),
            if (data.dueAt != null)
              pw.Text(
                '${data.dueLabel} ${_stamp.format(data.dueAt!)}',
                style: pw.TextStyle(
                  font: semiBold,
                  fontSize: 9.5,
                  color: data.overdue ? PdfColors.red800 : PdfColors.grey800,
                ),
              ),
          ],
        ),
      ],
    );
  }

  pw.Widget _parties(pw.Font semiBold) {
    final outstanding = data.lines.fold(0, (sum, l) => sum + l.outstanding);
    final facts = <(String, String)>[
      (data.partyLabel, data.partyName),
      ('Status', data.status),
      ('Lines', number(data.lines.length)),
      (
        'Outstanding',
        outstanding == 0 ? 'None' : '${number(outstanding)} units',
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
        1: pw.FlexColumnWidth(1.2),
        2: pw.FlexColumnWidth(1.4),
        3: pw.FlexColumnWidth(1.8),
        4: pw.FlexColumnWidth(1.9),
      },
      children: [
        pw.TableRow(
          children: [
            cell('ITEM', head: true),
            cell('QTY', head: true, align: pw.Alignment.centerRight),
            cell(
              data.settledLabel,
              head: true,
              align: pw.Alignment.centerRight,
            ),
            cell('UNIT', head: true, align: pw.Alignment.centerRight),
            cell('AMOUNT', head: true, align: pw.Alignment.centerRight),
          ],
        ),
        for (final line in data.lines)
          pw.TableRow(
            children: [
              cell(line.itemName),
              cell(number(line.quantity), align: pw.Alignment.centerRight),
              cell(
                // A dash rather than a zero: nothing has moved yet is a
                // different statement from none was asked for.
                line.settled == 0 ? '—' : number(line.settled),
                align: pw.Alignment.centerRight,
              ),
              cell(_money(line.unitPrice), align: pw.Alignment.centerRight),
              cell(_money(line.lineTotal), align: pw.Alignment.centerRight),
            ],
          ),
      ],
    );
  }

  pw.Widget _notes(pw.Font semiBold) {
    if (data.notes.trim().isEmpty) return pw.SizedBox();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'NOTES',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          data.notes,
          style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800),
        ),
      ],
    );
  }

  pw.Widget _totals(pw.Font semiBold, pw.Font bold) {
    return pw.Column(
      children: [
        pw.Divider(color: PdfColors.grey400, height: 12),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Order total',
              style: pw.TextStyle(font: bold, fontSize: 11),
            ),
            pw.Text(
              _money(data.total),
              style: pw.TextStyle(font: bold, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}
