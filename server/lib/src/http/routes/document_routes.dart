import 'package:drift/drift.dart' show Value;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../db/database.dart';
import '../../inventory/document_service.dart';
import '../api_error.dart';
import '../inventory_serializers.dart';
import '../middleware.dart';
import '../request_context.dart';

/// Invoices, receipts and the two kinds of order.
///
/// Split from the item and stock routes because these are where the money is:
/// a different set of permissions guards them, and the write paths have
/// side-effects on stock that the item routes deliberately do not.
Router documentRoutes({required DocumentService documents}) {
  final router = Router();

  // ------------------------------------------------------------------
  // Invoices
  // ------------------------------------------------------------------
  router.get('/invoices', (Request request) async {
    request.require('invoices.view');
    final rows = await documents.invoices(
      status: request.url.queryParameters['status'],
    );
    // One query for every line on the page, grouped here — not one pair of
    // queries per row, awaited in turn.
    final lines = await documents.invoiceLinesFor([
      for (final invoice in rows) invoice.id,
    ]);
    return jsonResponse({
      'invoices': [
        for (final invoice in rows)
          invoiceJson(invoice, lines[invoice.id] ?? const []),
      ],
    });
  });

  router.get('/invoices/<id>', (Request request, String id) async {
    request.require('invoices.view');
    final result = await documents.invoice(id);
    return jsonResponse({'invoice': invoiceJson(result.invoice, result.lines)});
  });

  router.post('/invoices', (Request request) async {
    final caller = request.require('invoices.create');
    final body = await readJsonBody(request);
    final saved = await documents.saveInvoice(
      header: _invoiceHeader(body),
      lines: _invoiceLines(body),
      actorId: caller.user.id,
    );
    return jsonResponse({
      'invoice': invoiceJson(saved.invoice, saved.lines),
    }, statusCode: 201);
  });

  router.patch('/invoices/<id>', (Request request, String id) async {
    final caller = request.require('invoices.update');
    final body = await readJsonBody(request);
    final saved = await documents.saveInvoice(
      header: _invoiceHeader(body).copyWith(id: Value(id)),
      lines: _invoiceLines(body),
      actorId: caller.user.id,
    );
    return jsonResponse({'invoice': invoiceJson(saved.invoice, saved.lines)});
  });

  /// Money taken against an invoice.
  ///
  /// A POST that adds, not a PATCH that sets: two tills settling the same
  /// invoice have to accumulate rather than overwrite each other.
  router.post('/invoices/<id>/payments', (Request request, String id) async {
    final caller = request.require('invoices.update');
    final body = await readJsonBody(request);

    final amount = body['amount'];
    if (amount is! num) {
      throw ApiError.badRequest('amount must be a number.');
    }

    final result = await documents.recordPayment(
      id: id,
      amount: amount.toDouble(),
      actorId: caller.user.id,
    );
    final lines = (await documents.invoice(id)).lines;
    return jsonResponse({
      'invoice': invoiceJson(result.invoice, lines),
      // What was actually taken, which is less than was offered when the
      // payment covered more than the balance. The till shows the difference
      // as change.
      'applied': result.applied,
    });
  });

  // The counter twin of the invoice payment above. A receipt raised against an
  // account can be left owing, and settling it had nowhere to go: the till
  // marked it paid on its own screen and the server never heard.
  router.post('/receipts/<id>/payments', (Request request, String id) async {
    final caller = request.require('receipts.create');
    final body = await readJsonBody(request);

    final amount = body['amount'];
    if (amount is! num) {
      throw ApiError.badRequest('amount must be a number.');
    }

    final result = await documents.settleReceipt(
      id: id,
      amount: amount.toDouble(),
      actorId: caller.user.id,
      method: body['method'] as String?,
    );
    final lines = (await documents.receipt(id)).lines;
    return jsonResponse({
      'receipt': receiptJson(result.receipt, lines),
      // What was actually taken; the difference is the customer's change.
      'applied': result.applied,
    });
  });

  // Cancelled rather than deleted: an invoice that was issued is a thing that
  // happened, and the stock it moved has to come back through a movement
  // rather than by the original quietly disappearing.
  router.post('/invoices/<id>/cancel', (Request request, String id) async {
    final caller = request.require('invoices.delete');
    final body = await readJsonBody(request);
    final invoice = await documents.cancelInvoice(
      id: id,
      actorId: caller.user.id,
      reason: body['reason'] as String? ?? '',
    );
    final lines = (await documents.invoice(id)).lines;
    return jsonResponse({'invoice': invoiceJson(invoice, lines)});
  });

  // ------------------------------------------------------------------
  // Receipts
  // ------------------------------------------------------------------
  router.get('/receipts', (Request request) async {
    request.require('receipts.view');
    final rows = await documents.receipts(
      status: request.url.queryParameters['status'],
    );
    final lines = await documents.receiptLinesFor([
      for (final receipt in rows) receipt.id,
    ]);
    return jsonResponse({
      'receipts': [
        for (final receipt in rows)
          receiptJson(receipt, lines[receipt.id] ?? const []),
      ],
    });
  });

  router.get('/receipts/<id>', (Request request, String id) async {
    request.require('receipts.view');
    final result = await documents.receipt(id);
    return jsonResponse({'receipt': receiptJson(result.receipt, result.lines)});
  });

  router.post('/receipts', (Request request) async {
    final caller = request.require('receipts.create');
    final body = await readJsonBody(request);
    final saved = await documents.saveReceipt(
      header: _receiptHeader(body),
      lines: _receiptLines(body),
      actorId: caller.user.id,
    );
    return jsonResponse({
      'receipt': receiptJson(saved.receipt, saved.lines),
    }, statusCode: 201);
  });

  router.post('/receipts/<id>/refund', (Request request, String id) async {
    final caller = request.require('receipts.create');
    final body = await readJsonBody(request);

    final raw = body['returned'];
    if (raw is! Map || raw.isEmpty) {
      throw ApiError.badRequest('returned must name at least one line.');
    }

    final returned = <String, int>{
      for (final entry in raw.entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };

    final result = await documents.refundReceipt(
      id: id,
      returnedByLineId: returned,
      actorId: caller.user.id,
      // Defaults to putting the goods back. Broken returns are the exception
      // and the caller has to say so.
      restock: body['restock'] != false,
      location: body['location'] as String? ?? 'Unassigned',
    );
    return jsonResponse({'receipt': receiptJson(result.receipt, result.lines)});
  });

  router.post('/receipts/<id>/void', (Request request, String id) async {
    final caller = request.require('receipts.create');
    final body = await readJsonBody(request);
    final receipt = await documents.voidReceipt(
      id: id,
      actorId: caller.user.id,
      reason: body['reason'] as String? ?? '',
    );
    final lines = (await documents.receipt(id)).lines;
    return jsonResponse({'receipt': receiptJson(receipt, lines)});
  });

  // ------------------------------------------------------------------
  // Purchase orders
  // ------------------------------------------------------------------
  router.get('/purchase-orders', (Request request) async {
    request.require('purchase_orders.view');
    final rows = await documents.purchaseOrders(
      status: request.url.queryParameters['status'],
    );
    final lines = await documents.purchaseOrderLinesFor([
      for (final order in rows) order.id,
    ]);
    return jsonResponse({
      'purchaseOrders': [
        for (final order in rows)
          purchaseOrderJson(order, lines[order.id] ?? const []),
      ],
    });
  });

  router.get('/purchase-orders/<id>', (Request request, String id) async {
    request.require('purchase_orders.view');
    final result = await documents.purchaseOrder(id);
    return jsonResponse({
      'purchaseOrder': purchaseOrderJson(result.order, result.lines),
    });
  });

  router.post('/purchase-orders', (Request request) async {
    request.require('purchase_orders.create');
    final body = await readJsonBody(request);
    final saved = await documents.savePurchaseOrder(
      header: _purchaseOrderHeader(body),
      lines: _purchaseOrderLines(body),
    );
    return jsonResponse({
      'purchaseOrder': purchaseOrderJson(saved.order, saved.lines),
    }, statusCode: 201);
  });

  router.patch('/purchase-orders/<id>', (Request request, String id) async {
    request.require('purchase_orders.update');
    final body = await readJsonBody(request);
    final saved = await documents.savePurchaseOrder(
      header: _purchaseOrderHeader(body).copyWith(id: Value(id)),
      lines: _purchaseOrderLines(body),
    );
    return jsonResponse({
      'purchaseOrder': purchaseOrderJson(saved.order, saved.lines),
    });
  });

  /// Receiving is what moves stock, not ordering.
  router.post('/purchase-orders/<id>/receive', (
    Request request,
    String id,
  ) async {
    final caller = request.require('inventory.adjust');
    final body = await readJsonBody(request);

    final raw = body['received'];
    if (raw is! Map || raw.isEmpty) {
      throw ApiError.badRequest('received must name at least one line.');
    }

    final received = <String, int>{
      for (final entry in raw.entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };

    final result = await documents.receiveGoods(
      orderId: id,
      receivedByLineId: received,
      actorId: caller.user.id,
      location: body['location'] as String? ?? 'Unassigned',
    );
    return jsonResponse({
      'purchaseOrder': purchaseOrderJson(result.order, result.lines),
    });
  });

  // ------------------------------------------------------------------
  // Sales orders
  // ------------------------------------------------------------------
  router.get('/sales-orders', (Request request) async {
    request.require('sales_orders.view');
    final rows = await documents.salesOrders(
      status: request.url.queryParameters['status'],
    );
    final lines = await documents.salesOrderLinesFor([
      for (final order in rows) order.id,
    ]);
    return jsonResponse({
      'salesOrders': [
        for (final order in rows)
          salesOrderJson(order, lines[order.id] ?? const []),
      ],
    });
  });

  router.get('/sales-orders/<id>', (Request request, String id) async {
    request.require('sales_orders.view');
    final result = await documents.salesOrder(id);
    return jsonResponse({
      'salesOrder': salesOrderJson(result.order, result.lines),
    });
  });

  router.post('/sales-orders', (Request request) async {
    request.require('sales_orders.create');
    final body = await readJsonBody(request);
    final saved = await documents.saveSalesOrder(
      header: _salesOrderHeader(body),
      lines: _salesOrderLines(body),
    );
    return jsonResponse({
      'salesOrder': salesOrderJson(saved.order, saved.lines),
    }, statusCode: 201);
  });

  router.patch('/sales-orders/<id>', (Request request, String id) async {
    request.require('sales_orders.update');
    final body = await readJsonBody(request);
    final saved = await documents.saveSalesOrder(
      header: _salesOrderHeader(body).copyWith(id: Value(id)),
      lines: _salesOrderLines(body),
    );
    return jsonResponse({
      'salesOrder': salesOrderJson(saved.order, saved.lines),
    });
  });

  // Cancelling puts back whatever the order sent, and cancels any unpaid
  // invoice billing it. The answer carries those invoices so the app can
  // adopt them rather than guess.
  router.post('/sales-orders/<id>/cancel', (Request request, String id) async {
    final caller = request.require('sales_orders.update');
    final body = await readJsonBody(request);
    final result = await documents.cancelSalesOrder(
      id: id,
      actorId: caller.user.id,
      reason: body['reason'] as String? ?? '',
    );
    return jsonResponse({
      'salesOrder': salesOrderJson(result.order, result.lines),
      'invoices': [
        for (final invoice in result.invoices)
          invoiceJson(invoice, (await documents.invoice(invoice.id)).lines),
      ],
    });
  });

  // Repairs for sales cancelled before cancelling returned stock. The scan is
  // read-only; the fix is per order, or every fixable one at once. Both are
  // administration: they move stock on records other people raised.
  router.get('/repairs/cancelled-sales', (Request request) async {
    request.require('settings.manage');
    final issues = await documents.scanCancelledSales();
    return jsonResponse({
      'issues': [for (final issue in issues) issue.toJson()],
    });
  });

  router.post('/repairs/cancelled-sales/<id>', (
    Request request,
    String id,
  ) async {
    final caller = request.require('settings.manage');
    final result = await documents.repairCancelledSale(
      id: id,
      actorId: caller.user.id,
    );
    return jsonResponse({
      'salesOrder': salesOrderJson(result.order, result.lines),
      'invoices': [
        for (final invoice in result.invoices)
          invoiceJson(invoice, (await documents.invoice(invoice.id)).lines),
      ],
    });
  });

  router.post('/repairs/cancelled-sales', (Request request) async {
    final caller = request.require('settings.manage');
    final repaired = <String>[];
    final skipped = <Map<String, String>>[];
    for (final issue in await documents.scanCancelledSales()) {
      if (!issue.fixable) {
        skipped.add({
          'reference': issue.salesOrderReference,
          'reason': 'Paid against (${issue.paidBy.join(', ')}). Refund first.',
        });
        continue;
      }
      try {
        await documents.repairCancelledSale(
          id: issue.salesOrderId,
          actorId: caller.user.id,
        );
        repaired.add(issue.salesOrderReference);
      } on ApiError catch (error) {
        skipped.add({
          'reference': issue.salesOrderReference,
          'reason': error.message,
        });
      }
    }
    return jsonResponse({'repaired': repaired, 'skipped': skipped});
  });

  /// Despatching is what moves stock, not confirming the order.
  router.post('/sales-orders/<id>/despatch', (
    Request request,
    String id,
  ) async {
    final caller = request.require('inventory.adjust');
    final body = await readJsonBody(request);

    final raw = body['sent'];
    if (raw is! Map || raw.isEmpty) {
      throw ApiError.badRequest('sent must name at least one line.');
    }

    final sent = <String, int>{
      for (final entry in raw.entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };

    final result = await documents.despatchGoods(
      orderId: id,
      sentByLineId: sent,
      actorId: caller.user.id,
      location: body['location'] as String? ?? 'Unassigned',
    );
    return jsonResponse({
      'salesOrder': salesOrderJson(result.order, result.lines),
    });
  });

  // ------------------------------------------------------------------
  // Transfers — created through /inventory/stock/transfer, read here
  // ------------------------------------------------------------------
  router.get('/transfers', (Request request) async {
    request.require('inventory.transfer');
    final rows = await documents.transfers();
    final lines = await documents.transferLinesFor([
      for (final t in rows) t.id,
    ]);
    return jsonResponse({
      'transfers': [
        for (final t in rows) transferJson(t, lines[t.id] ?? const []),
      ],
    });
  });

  router.get('/transfers/<id>', (Request request, String id) async {
    request.require('inventory.transfer');
    final result = await documents.transfer(id);
    return jsonResponse({
      'transfer': transferJson(result.transfer, result.lines),
    });
  });

  return router;
}

// --------------------------------------------------------------------
// Body mapping
// --------------------------------------------------------------------

InvoicesCompanion _invoiceHeader(Map<String, Object?> b) => InvoicesCompanion(
  id: _opt(b, 'id'),
  reference: _opt(b, 'reference'),
  salesOrderId: _opt(b, 'salesOrderId'),
  customerId: _opt(b, 'customerId'),
  customerName: _opt(b, 'customerName'),
  status: _opt(b, 'status'),
  discount: _optDouble(b, 'discount'),
  taxRate: _optDouble(b, 'taxRate'),
  taxLabel: _opt(b, 'taxLabel'),
  amountPaid: _optDouble(b, 'amountPaid'),
  terms: _opt(b, 'terms'),
  notes: _opt(b, 'notes'),
  movesStock: _optBool(b, 'movesStock'),
  issuedAt: Value(_date(b['issuedAt']) ?? DateTime.now().toUtc()),
  dueAt: _optDate(b, 'dueAt'),
  closedAt: _optDate(b, 'closedAt'),
  cancelledReason: _opt(b, 'cancelledReason'),
);

List<InvoiceLinesCompanion> _invoiceLines(Map<String, Object?> b) => [
  for (final line in _lines(b))
    InvoiceLinesCompanion.insert(
      id: _lineId(line),
      invoiceId: '',
      itemId: _req(line, 'itemId'),
      itemName: _req(line, 'itemName'),
      quantity: _reqInt(line, 'quantity'),
      sku: _opt(line, 'sku'),
      unit: _opt(line, 'unit'),
      unitPrice: _optDouble(line, 'unitPrice'),
      discount: _optDouble(line, 'discount'),
      costOfGoods: _optDouble(line, 'costOfGoods'),
    ),
];

ReceiptsCompanion _receiptHeader(Map<String, Object?> b) => ReceiptsCompanion(
  id: _opt(b, 'id'),
  reference: _opt(b, 'reference'),
  salesOrderId: _opt(b, 'salesOrderId'),
  invoiceId: _opt(b, 'invoiceId'),
  customerId: _opt(b, 'customerId'),
  customerName: _opt(b, 'customerName'),
  status: _opt(b, 'status'),
  method: _opt(b, 'method'),
  discount: _optDouble(b, 'discount'),
  taxRate: _optDouble(b, 'taxRate'),
  taxLabel: _opt(b, 'taxLabel'),
  amountPaid: _optDouble(b, 'amountPaid'),
  notes: _opt(b, 'notes'),
  cashier: _opt(b, 'cashier'),
  movesStock: _optBool(b, 'movesStock'),
  issuedAt: Value(_date(b['issuedAt']) ?? DateTime.now().toUtc()),
  voidReason: _opt(b, 'voidReason'),
);

List<ReceiptLinesCompanion> _receiptLines(Map<String, Object?> b) => [
  for (final line in _lines(b))
    ReceiptLinesCompanion.insert(
      id: _lineId(line),
      receiptId: '',
      itemId: _req(line, 'itemId'),
      itemName: _req(line, 'itemName'),
      quantity: _reqInt(line, 'quantity'),
      sku: _opt(line, 'sku'),
      unit: _opt(line, 'unit'),
      unitPrice: _optDouble(line, 'unitPrice'),
      discount: _optDouble(line, 'discount'),
      quantityRefunded: _optInt(line, 'quantityRefunded'),
      costOfGoods: _optDouble(line, 'costOfGoods'),
    ),
];

PurchaseOrdersCompanion _purchaseOrderHeader(Map<String, Object?> b) =>
    PurchaseOrdersCompanion(
      id: _opt(b, 'id'),
      reference: _opt(b, 'reference'),
      supplierId: _opt(b, 'supplierId'),
      supplierName: _opt(b, 'supplierName'),
      status: _opt(b, 'status'),
      orderedAt: _optDate(b, 'orderedAt'),
      expectedAt: _optDate(b, 'expectedAt'),
      closedAt: _optDate(b, 'closedAt'),
      notes: _opt(b, 'notes'),
    );

List<PurchaseOrderLinesCompanion> _purchaseOrderLines(Map<String, Object?> b) =>
    [
      for (final line in _lines(b))
        PurchaseOrderLinesCompanion.insert(
          id: _lineId(line),
          orderId: '',
          itemId: _req(line, 'itemId'),
          itemName: _req(line, 'itemName'),
          quantityOrdered: _reqInt(line, 'quantityOrdered'),
          quantityReceived: _optInt(line, 'quantityReceived'),
          unitCost: _optDouble(line, 'unitCost'),
        ),
    ];

SalesOrdersCompanion _salesOrderHeader(Map<String, Object?> b) =>
    SalesOrdersCompanion(
      id: _opt(b, 'id'),
      reference: _opt(b, 'reference'),
      customerId: _opt(b, 'customerId'),
      customerName: _opt(b, 'customerName'),
      priceTier: _opt(b, 'priceTier'),
      status: _opt(b, 'status'),
      confirmedAt: _optDate(b, 'confirmedAt'),
      dueAt: _optDate(b, 'dueAt'),
      closedAt: _optDate(b, 'closedAt'),
      notes: _opt(b, 'notes'),
    );

List<SalesOrderLinesCompanion> _salesOrderLines(Map<String, Object?> b) => [
  for (final line in _lines(b))
    SalesOrderLinesCompanion.insert(
      id: _lineId(line),
      orderId: '',
      itemId: _req(line, 'itemId'),
      itemName: _req(line, 'itemName'),
      quantityOrdered: _reqInt(line, 'quantityOrdered'),
      quantityFulfilled: _optInt(line, 'quantityFulfilled'),
      unitPrice: _optDouble(line, 'unitPrice'),
      costOfGoods: _optDouble(line, 'costOfGoods'),
    ),
];

List<Map<String, Object?>> _lines(Map<String, Object?> body) {
  final raw = body['lines'];
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map) entry.cast<String, Object?>(),
  ];
}

/// The service fills a blank in, so an id is optional on the way in.
String _lineId(Map<String, Object?> line) {
  final id = line['id'];
  return id is String && id.isNotEmpty ? id : '';
}

Value<T> _opt<T>(Map<String, Object?> b, String key) =>
    b.containsKey(key) ? Value(b[key] as T) : const Value.absent();

Value<int> _optInt(Map<String, Object?> b, String key) => b.containsKey(key)
    ? Value((b[key] as num?)?.toInt() ?? 0)
    : const Value.absent();

Value<double> _optDouble(Map<String, Object?> b, String key) =>
    b.containsKey(key)
    ? Value((b[key] as num?)?.toDouble() ?? 0)
    : const Value.absent();

Value<bool> _optBool(Map<String, Object?> b, String key) =>
    b.containsKey(key) ? Value(b[key] == true) : const Value.absent();

/// Nullable on purpose: these columns are, and sending an explicit null is how
/// a caller clears a due date rather than leaving it untouched. Absent still
/// means "do not change it".
Value<DateTime?> _optDate(Map<String, Object?> b, String key) {
  if (!b.containsKey(key)) return const Value.absent();
  return Value(_date(b[key]));
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String _req(Map<String, Object?> b, String key) {
  final value = b[key];
  if (value is! String || value.trim().isEmpty) {
    throw ApiError.badRequest('$key is required on every line.');
  }
  return value.trim();
}

int _reqInt(Map<String, Object?> b, String key) {
  final value = b[key];
  if (value is! num) throw ApiError.badRequest('$key must be a number.');
  return value.toInt();
}
