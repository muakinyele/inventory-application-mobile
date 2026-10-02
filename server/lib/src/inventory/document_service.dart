import 'package:drift/drift.dart';

import '../auth/tokens.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import 'inventory_service.dart';

/// Invoices, receipts, and the two kinds of order.
///
/// The stock rule from [InventoryService] holds here too: a document that
/// moves stock does so inside the same transaction that saves it, and every
/// unit that moves leaves a movement behind carrying the document's id.
///
/// That id is also what makes the effect idempotent. Whether a document has
/// already moved its stock is answered by asking whether movements exist for
/// it, rather than by a flag on the row that a retry could get wrong — a
/// half-applied invoice is not a state worth being able to represent.
class DocumentService {
  DocumentService(this.db, this.inventory);

  final AuthDatabase db;
  final InventoryService inventory;

  // ------------------------------------------------------------------
  // Invoices
  // ------------------------------------------------------------------

  Future<List<Invoice>> invoices({String? status, int limit = 200}) {
    final query = db.select(db.invoices);
    if (status != null && status.isNotEmpty) {
      query.where((t) => t.status.equals(status));
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.issuedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<({Invoice invoice, List<InvoiceLine> lines})> invoice(
    String id,
  ) async {
    final row = await (db.select(
      db.invoices,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw ApiError.notFound;
    return (invoice: row, lines: await _invoiceLines(id));
  }

  // ------------------------------------------------------------------
  // Lines for a LIST of documents
  //
  // THE LIST ENDPOINTS WERE N+1, AND THEN SOME. Each one fetched its rows and
  // then, for every row, called the single-document reader — which re-SELECTS
  // a row the caller already has and then queries its lines. Awaited inside
  // the loop, so sequentially. At the default limit of 200 that is 1 + 200 × 2
  // = 401 round trips to answer one request, and five such endpoints are
  // fetched in parallel when the app starts.
  //
  // One query per list instead, grouped in memory. The ordering is kept where
  // the single readers had it, so a document's lines still come back in the
  // order they were entered.
  // ------------------------------------------------------------------

  Future<Map<String, List<InvoiceLine>>> invoiceLinesFor(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows =
        await (db.select(db.invoiceLines)
              ..where((t) => t.invoiceId.isIn(ids))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
    return _groupBy(rows, (row) => row.invoiceId);
  }

  Future<Map<String, List<ReceiptLine>>> receiptLinesFor(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows =
        await (db.select(db.receiptLines)
              ..where((t) => t.receiptId.isIn(ids))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
    return _groupBy(rows, (row) => row.receiptId);
  }

  Future<Map<String, List<PurchaseOrderLine>>> purchaseOrderLinesFor(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows =
        await (db.select(db.purchaseOrderLines)
              ..where((t) => t.orderId.isIn(ids))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
    return _groupBy(rows, (row) => row.orderId);
  }

  Future<Map<String, List<SalesOrderLine>>> salesOrderLinesFor(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows =
        await (db.select(db.salesOrderLines)
              ..where((t) => t.orderId.isIn(ids))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
    return _groupBy(rows, (row) => row.orderId);
  }

  Future<Map<String, List<TransferLine>>> transferLinesFor(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows = await (db.select(
      db.transferLines,
    )..where((t) => t.transferId.isIn(ids))).get();
    return _groupBy(rows, (row) => row.transferId);
  }

  Map<String, List<T>> _groupBy<T>(List<T> rows, String Function(T) key) {
    final grouped = <String, List<T>>{};
    for (final row in rows) {
      (grouped[key(row)] ??= []).add(row);
    }
    return grouped;
  }

  Future<List<InvoiceLine>> _invoiceLines(String id) =>
      (db.select(db.invoiceLines)
            ..where((t) => t.invoiceId.equals(id))
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  /// Saves an invoice and, when it moves stock, applies it.
  ///
  /// Lines are replaced wholesale rather than diffed: the editor owns their
  /// order and a line can be removed, and reconciling that row by row buys
  /// nothing when the whole document is written in one transaction anyway.
  Future<({Invoice invoice, List<InvoiceLine> lines})> saveInvoice({
    required InvoicesCompanion header,
    required List<InvoiceLinesCompanion> lines,
    required String actorId,
  }) async {
    return db.transaction(() async {
      final now = DateTime.now().toUtc();
      final id = idOrNew(header.id);

      final existing = await (db.select(
        db.invoices,
      )..where((t) => t.id.equals(id))).getSingleOrNull();

      if (existing == null) {
        await db
            .into(db.invoices)
            .insert(
              header.copyWith(
                id: Value(id),
                reference: Value(
                  header.reference.present && header.reference.value.isNotEmpty
                      ? header.reference.value
                      : await _nextReference('invoice', 'INV-'),
                ),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      } else {
        await (db.update(db.invoices)..where((t) => t.id.equals(id))).write(
          header.copyWith(
            id: const Value.absent(),
            createdAt: const Value.absent(),
            updatedAt: Value(now),
          ),
        );
      }

      await (db.delete(
        db.invoiceLines,
      )..where((t) => t.invoiceId.equals(id))).go();

      var position = 0;
      for (final line in lines) {
        await db
            .into(db.invoiceLines)
            .insert(
              line.copyWith(
                // Present-but-empty is how a new line arrives: the route fills the
                // field in because the companion requires it, and only the service
                // knows whether this is an insert. Treating that as an id gives
                // every new line the same one.
                id: Value(
                  line.id.present && line.id.value.isNotEmpty
                      ? line.id.value
                      : newId(),
                ),
                invoiceId: Value(id),
                position: Value(position++),
              ),
            );
      }

      final saved = await (db.select(
        db.invoices,
      )..where((t) => t.id.equals(id))).getSingle();

      // A proforma prints like an invoice and must not touch stock; a
      // cancelled one has had its effect reversed already.
      if (saved.movesStock && saved.status != 'cancelled') {
        await _applyDocumentStock(
          documentId: id,
          kind: 'sale',
          actorId: actorId,
          note: 'Invoice ${saved.reference}',
          lines: [
            for (final line in await _invoiceLines(id))
              (itemId: line.itemId, quantity: line.quantity),
          ],
          direction: -1,
        );
      }

      return (invoice: saved, lines: await _invoiceLines(id));
    });
  }

  /// Records money taken against an invoice.
  ///
  /// An operation rather than a field, which is the whole point. While
  /// `amountPaid` was something each client wrote, two people settling the
  /// same invoice each sent their own total and the second silently replaced
  /// the first — the later payment looked like the only one, and the money in
  /// between vanished from the record. Here the running total is read and
  /// added to inside one transaction, so payments accumulate.
  ///
  /// The amount is capped at the balance. Anything beyond it is change, not
  /// revenue, and an invoice that reads as more than paid is a figure nobody
  /// can reconcile. What was actually applied comes back in the invoice, so
  /// the till can show the difference.
  Future<({Invoice invoice, double applied})> recordPayment({
    required String id,
    required double amount,
    required String actorId,
  }) async {
    if (amount <= 0) {
      throw ApiError.badRequest('A payment has to be more than nothing.');
    }

    return db.transaction(() async {
      final invoice = await (db.select(
        db.invoices,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (invoice == null) throw ApiError.notFound;

      if (invoice.status == 'cancelled') {
        throw ApiError.badRequest(
          'Invoice ${invoice.reference} was cancelled and takes no payment.',
        );
      }

      final lines = await _invoiceLines(id);
      final total = _invoiceTotal(invoice, lines);
      final balance = total - invoice.amountPaid;

      // Rounded the way the client's isSettled is, so a total of 4999.999999
      // out of a percentage tax does not leave an invoice owing a hundredth of
      // a penny forever.
      if (balance < 0.005) {
        throw ApiError.badRequest(
          'Invoice ${invoice.reference} is already settled.',
        );
      }

      final applied = amount > balance ? balance : amount;
      final paid = invoice.amountPaid + applied;
      final settled = (total - paid) < 0.005;
      final now = DateTime.now().toUtc();

      await (db.update(db.invoices)..where((t) => t.id.equals(id))).write(
        InvoicesCompanion(
          amountPaid: Value(paid),
          // Matching the client's InvoiceStatus members by name.
          status: Value(settled ? 'paid' : 'partPaid'),
          closedAt: settled ? Value(now) : const Value.absent(),
          updatedAt: Value(now),
        ),
      );

      return (
        invoice: await (db.select(
          db.invoices,
        )..where((t) => t.id.equals(id))).getSingle(),
        applied: applied,
      );
    });
  }

  /// The invoice's total, computed the same way the client computes it.
  ///
  /// Duplicated deliberately rather than trusted from the request: a balance
  /// the payer supplies is a balance the payer can be wrong about, and this is
  /// the number that decides whether money is owed.
  double _invoiceTotal(Invoice invoice, List<InvoiceLine> lines) {
    final gross = lines.fold(0.0, (sum, l) => sum + l.quantity * l.unitPrice);
    final lineDiscount = lines.fold(0.0, (sum, l) => sum + l.discount);

    // Capped at the goods themselves, so an over-generous discount cannot make
    // an invoice negative.
    final discount = (lineDiscount + invoice.discount).clamp(
      0.0,
      gross <= 0 ? 0.0 : gross,
    );
    final subtotal = (gross - discount).clamp(0.0, double.infinity);
    return subtotal + subtotal * invoice.taxRate;
  }

  /// Takes money against an outstanding receipt.
  ///
  /// The counter twin of [recordPayment]. A receipt is usually paid in full at
  /// the till, but one raised against an account can be left owing — and until
  /// now settling it happened only on the device that did it, because there
  /// was no endpoint to tell.
  ///
  /// Adds rather than overwrites, for the same reason invoices do: two tills
  /// taking money against the same receipt must accumulate, not race.
  Future<({Receipt receipt, double applied})> settleReceipt({
    required String id,
    required double amount,
    required String actorId,
    String? method,
  }) async {
    if (amount <= 0) {
      throw ApiError.badRequest('A payment has to be more than nothing.');
    }

    return db.transaction(() async {
      final receipt = await (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (receipt == null) throw ApiError.notFound;

      if (receipt.status == 'voided') {
        throw ApiError.badRequest(
          'Receipt ${receipt.reference} was voided and takes no payment.',
        );
      }

      final lines = await _receiptLines(id);
      final total = _receiptTotal(receipt, lines);
      final balance = total - receipt.amountPaid;

      // The same hundredth-of-a-penny rounding the invoice path uses, so a
      // percentage tax cannot leave a receipt owing forever.
      if (balance < 0.005) {
        throw ApiError.badRequest(
          'Receipt ${receipt.reference} is already settled.',
        );
      }

      final applied = amount > balance ? balance : amount;
      final now = DateTime.now().toUtc();

      await (db.update(db.receipts)..where((t) => t.id.equals(id))).write(
        ReceiptsCompanion(
          amountPaid: Value(receipt.amountPaid + applied),
          method: method == null ? const Value.absent() : Value(method),
          updatedAt: Value(now),
        ),
      );

      return (
        receipt: await (db.select(
          db.receipts,
        )..where((t) => t.id.equals(id))).getSingle(),
        applied: applied,
      );
    });
  }

  /// What a receipt comes to, by the same arithmetic as an invoice: a refund
  /// reduces what is owed, so refunded quantities come out of the goods before
  /// the tax goes on.
  double _receiptTotal(Receipt receipt, List<ReceiptLine> lines) {
    final gross = lines.fold(
      0.0,
      (sum, l) => sum + (l.quantity - l.quantityRefunded) * l.unitPrice,
    );
    final lineDiscount = lines.fold(0.0, (sum, l) => sum + l.discount);
    final discount = (lineDiscount + receipt.discount).clamp(
      0.0,
      gross <= 0 ? 0.0 : gross,
    );
    final subtotal = (gross - discount).clamp(0.0, double.infinity);
    return subtotal + subtotal * receipt.taxRate;
  }

  /// Cancels an invoice and puts the stock back.
  ///
  /// Never deleted. An invoice that was issued is a thing that happened, and
  /// the reversal is itself a movement rather than the quiet disappearance of
  /// the original.
  Future<Invoice> cancelInvoice({
    required String id,
    required String actorId,
    String reason = '',
  }) async {
    return db.transaction(() async {
      final current = await (db.select(
        db.invoices,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (current == null) throw ApiError.notFound;
      if (current.status == 'cancelled') return current;

      // Cancelling returns the stock. With money already taken against the
      // invoice that would put the goods back on the shelf and leave the
      // payment banked — the books and the shelf disagreeing, with nothing on
      // either side recording why. A paid invoice is refunded or credited,
      // not struck off.
      if (current.amountPaid > 0) {
        throw ApiError.badRequest(
          'Invoice ${current.reference} has been paid against and cannot be '
          'cancelled. Refund the payment first.',
        );
      }

      if (current.movesStock) {
        await _reverseDocumentStock(
          documentId: id,
          actorId: actorId,
          note: 'Cancelled invoice ${current.reference}',
          kind: 'cancellation',
        );
      }

      await (db.update(db.invoices)..where((t) => t.id.equals(id))).write(
        InvoicesCompanion(
          status: const Value('cancelled'),
          cancelledReason: Value(reason),
          closedAt: Value(DateTime.now().toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      return (db.select(
        db.invoices,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  // ------------------------------------------------------------------
  // Receipts
  // ------------------------------------------------------------------

  Future<List<Receipt>> receipts({String? status, int limit = 200}) {
    final query = db.select(db.receipts);
    if (status != null && status.isNotEmpty) {
      query.where((t) => t.status.equals(status));
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.issuedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<({Receipt receipt, List<ReceiptLine> lines})> receipt(
    String id,
  ) async {
    final row = await (db.select(
      db.receipts,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw ApiError.notFound;
    return (receipt: row, lines: await _receiptLines(id));
  }

  Future<List<ReceiptLine>> _receiptLines(String id) =>
      (db.select(db.receiptLines)
            ..where((t) => t.receiptId.equals(id))
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  Future<({Receipt receipt, List<ReceiptLine> lines})> saveReceipt({
    required ReceiptsCompanion header,
    required List<ReceiptLinesCompanion> lines,
    required String actorId,
  }) async {
    return db.transaction(() async {
      final now = DateTime.now().toUtc();
      final id = idOrNew(header.id);

      final existing = await (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingleOrNull();

      if (existing == null) {
        await db
            .into(db.receipts)
            .insert(
              header.copyWith(
                id: Value(id),
                reference: Value(
                  header.reference.present && header.reference.value.isNotEmpty
                      ? header.reference.value
                      : await _nextReference('receipt', 'RC-'),
                ),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      } else {
        await (db.update(db.receipts)..where((t) => t.id.equals(id))).write(
          header.copyWith(
            id: const Value.absent(),
            createdAt: const Value.absent(),
            updatedAt: Value(now),
          ),
        );
      }

      await (db.delete(
        db.receiptLines,
      )..where((t) => t.receiptId.equals(id))).go();

      var position = 0;
      for (final line in lines) {
        await db
            .into(db.receiptLines)
            .insert(
              line.copyWith(
                // Present-but-empty is how a new line arrives: the route fills the
                // field in because the companion requires it, and only the service
                // knows whether this is an insert. Treating that as an id gives
                // every new line the same one.
                id: Value(
                  line.id.present && line.id.value.isNotEmpty
                      ? line.id.value
                      : newId(),
                ),
                receiptId: Value(id),
                position: Value(position++),
              ),
            );
      }

      final saved = await (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingle();

      if (saved.movesStock && saved.status == 'issued') {
        await _applyDocumentStock(
          documentId: id,
          kind: 'sale',
          actorId: actorId,
          note: 'Receipt ${saved.reference}',
          lines: [
            for (final line in await _receiptLines(id))
              (itemId: line.itemId, quantity: line.quantity),
          ],
          direction: -1,
        );
      }

      return (receipt: saved, lines: await _receiptLines(id));
    });
  }

  /// Takes goods back against a receipt.
  ///
  /// Distinct from a void, which tears the whole document up and is only
  /// allowed while nothing has come back. A refund is partial by nature: each
  /// line is clamped to what is still kept, and the receipt settles to
  /// `refunded` only once every line has been returned in full.
  ///
  /// [restock] is the reason this cannot simply mirror the sale. Goods that
  /// come back saleable go on the shelf; goods that come back broken do not,
  /// and the money is still refunded either way. Stock and money part company
  /// here, which is why the flag exists rather than being inferred.
  Future<({Receipt receipt, List<ReceiptLine> lines})> refundReceipt({
    required String id,
    required Map<String, int> returnedByLineId,
    required String actorId,
    bool restock = true,
    String location = InventoryService.unassigned,
  }) async {
    return db.transaction(() async {
      final receipt = await (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (receipt == null) throw ApiError.notFound;
      if (receipt.status == 'voided') {
        throw ApiError.badRequest('A voided receipt has nothing to refund.');
      }

      final lines = await _receiptLines(id);
      final byId = {for (final line in lines) line.id: line};
      var touched = 0;

      for (final entry in returnedByLineId.entries) {
        final line = byId[entry.key];
        if (line == null) {
          throw ApiError.badRequest('No line ${entry.key} on this receipt.');
        }
        final kept = line.quantity - line.quantityRefunded;
        final quantity = entry.value > kept ? kept : entry.value;
        if (quantity <= 0) continue;

        touched++;
        await (db.update(
          db.receiptLines,
        )..where((t) => t.id.equals(line.id))).write(
          ReceiptLinesCompanion(
            quantityRefunded: Value(line.quantityRefunded + quantity),
          ),
        );

        // Only a receipt that took stock has any to give back, and only if the
        // goods are fit to sell again.
        if (restock && receipt.movesStock) {
          await inventory.adjustStock(
            itemId: line.itemId,
            delta: quantity,
            kind: 'refund',
            actorId: actorId,
            location: location,
            note: 'Returned on ${receipt.reference}',
            documentId: id,
          );
        }
      }

      if (touched == 0) {
        return (receipt: receipt, lines: lines);
      }

      final updated = await _receiptLines(id);
      final settled = updated.every(
        (line) => line.quantityRefunded >= line.quantity,
      );
      final now = DateTime.now().toUtc();

      await (db.update(db.receipts)..where((t) => t.id.equals(id))).write(
        ReceiptsCompanion(
          // These match the client's ReceiptStatus members by name; a value it
          // cannot parse falls back to `issued`, which would show a refunded
          // sale as live.
          status: Value(settled ? 'refunded' : 'partRefunded'),
          refundedAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      return (
        receipt: await (db.select(
          db.receipts,
        )..where((t) => t.id.equals(id))).getSingle(),
        lines: updated,
      );
    });
  }

  /// Voids a receipt and returns the stock.
  Future<Receipt> voidReceipt({
    required String id,
    required String actorId,
    String reason = '',
  }) async {
    return db.transaction(() async {
      final current = await (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (current == null) throw ApiError.notFound;
      // 'voided', not 'void': this string is read straight back into the
      // client's ReceiptStatus enum, whose member is `voided`. A value it
      // cannot match degrades to `issued` — a voided receipt showing as live,
      // which is the worst way for this to be wrong.
      if (current.status == 'voided') return current;

      if (current.movesStock) {
        await _reverseDocumentStock(
          documentId: id,
          actorId: actorId,
          note: 'Voided receipt ${current.reference}',
          kind: 'void',
        );
      }

      final now = DateTime.now().toUtc();
      await (db.update(db.receipts)..where((t) => t.id.equals(id))).write(
        ReceiptsCompanion(
          status: const Value('voided'),
          voidReason: Value(reason),
          voidedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      return (db.select(
        db.receipts,
      )..where((t) => t.id.equals(id))).getSingle();
    });
  }

  // ------------------------------------------------------------------
  // Purchase orders
  // ------------------------------------------------------------------

  Future<List<PurchaseOrder>> purchaseOrders({
    String? status,
    int limit = 200,
  }) {
    final query = db.select(db.purchaseOrders);
    if (status != null && status.isNotEmpty) {
      query.where((t) => t.status.equals(status));
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<({PurchaseOrder order, List<PurchaseOrderLine> lines})> purchaseOrder(
    String id,
  ) async {
    final row = await (db.select(
      db.purchaseOrders,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw ApiError.notFound;
    return (order: row, lines: await _purchaseOrderLines(id));
  }

  Future<List<PurchaseOrderLine>> _purchaseOrderLines(String id) =>
      (db.select(db.purchaseOrderLines)
            ..where((t) => t.orderId.equals(id))
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  /// Saves a purchase order. Ordering stock does not move it; receiving does.
  Future<({PurchaseOrder order, List<PurchaseOrderLine> lines})>
  savePurchaseOrder({
    required PurchaseOrdersCompanion header,
    required List<PurchaseOrderLinesCompanion> lines,
  }) async {
    return db.transaction(() async {
      final now = DateTime.now().toUtc();
      final id = idOrNew(header.id);

      final existing = await (db.select(
        db.purchaseOrders,
      )..where((t) => t.id.equals(id))).getSingleOrNull();

      if (existing == null) {
        await db
            .into(db.purchaseOrders)
            .insert(
              header.copyWith(
                id: Value(id),
                reference: Value(
                  header.reference.present && header.reference.value.isNotEmpty
                      ? header.reference.value
                      : await _nextReference('purchase_order', 'PO-'),
                ),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      } else {
        await (db.update(
          db.purchaseOrders,
        )..where((t) => t.id.equals(id))).write(
          header.copyWith(
            id: const Value.absent(),
            createdAt: const Value.absent(),
            updatedAt: Value(now),
          ),
        );
      }

      await (db.delete(
        db.purchaseOrderLines,
      )..where((t) => t.orderId.equals(id))).go();

      var position = 0;
      for (final line in lines) {
        await db
            .into(db.purchaseOrderLines)
            .insert(
              line.copyWith(
                // Present-but-empty is how a new line arrives: the route fills the
                // field in because the companion requires it, and only the service
                // knows whether this is an insert. Treating that as an id gives
                // every new line the same one.
                id: Value(
                  line.id.present && line.id.value.isNotEmpty
                      ? line.id.value
                      : newId(),
                ),
                orderId: Value(id),
                position: Value(position++),
              ),
            );
      }

      return (
        order: await (db.select(
          db.purchaseOrders,
        )..where((t) => t.id.equals(id))).getSingle(),
        lines: await _purchaseOrderLines(id),
      );
    });
  }

  /// Receives goods against an order: stock in, and the line's received count
  /// moves up by what actually arrived.
  ///
  /// Partial deliveries are the normal case, so this takes what turned up
  /// rather than assuming the whole order did.
  Future<({PurchaseOrder order, List<PurchaseOrderLine> lines})> receiveGoods({
    required String orderId,
    required Map<String, int> receivedByLineId,
    required String actorId,
    String location = InventoryService.unassigned,
  }) async {
    return db.transaction(() async {
      final order = await (db.select(
        db.purchaseOrders,
      )..where((t) => t.id.equals(orderId))).getSingleOrNull();
      if (order == null) throw ApiError.notFound;

      if (order.status == 'cancelled') {
        throw ApiError.badRequest(
          'Order ${order.reference} was cancelled; it cannot take a delivery.',
        );
      }

      final lines = await _purchaseOrderLines(orderId);
      final byId = {for (final line in lines) line.id: line};

      for (final entry in receivedByLineId.entries) {
        final line = byId[entry.key];
        if (line == null) {
          throw ApiError.badRequest('No line ${entry.key} on this order.');
        }
        final quantity = entry.value;
        if (quantity <= 0) continue;

        final outstanding = line.quantityOrdered - line.quantityReceived;
        if (quantity > outstanding) {
          throw ApiError.badRequest(
            '${line.itemName} has $outstanding outstanding, not $quantity.',
          );
        }

        // Cost first, while the old count is still readable: the average is
        // weighted by what was already on the shelf, and adjustStock is about
        // to change that.
        await _rollForwardCost(line.itemId, quantity, line.unitCost);

        await inventory.adjustStock(
          itemId: line.itemId,
          delta: quantity,
          kind: 'receipt',
          actorId: actorId,
          location: location,
          note: 'Received on ${order.reference}',
          documentId: orderId,
        );

        await (db.update(
          db.purchaseOrderLines,
        )..where((t) => t.id.equals(line.id))).write(
          PurchaseOrderLinesCompanion(
            quantityReceived: Value(line.quantityReceived + quantity),
          ),
        );
      }

      final updated = await _purchaseOrderLines(orderId);
      final complete = updated.every(
        (line) => line.quantityReceived >= line.quantityOrdered,
      );
      final now = DateTime.now().toUtc();

      await (db.update(
        db.purchaseOrders,
      )..where((t) => t.id.equals(orderId))).write(
        PurchaseOrdersCompanion(
          status: Value(complete ? 'received' : 'partial'),
          closedAt: complete ? Value(now) : const Value.absent(),
          updatedAt: Value(now),
        ),
      );

      return (
        order: await (db.select(
          db.purchaseOrders,
        )..where((t) => t.id.equals(orderId))).getSingle(),
        lines: updated,
      );
    });
  }

  /// Moves an item's unit cost to the weighted average of what it held and
  /// what has just arrived.
  ///
  /// Ten on hand at 1.00 and ten arriving at 2.00 makes the shelf worth 30
  /// across twenty units, so the cost becomes 1.50. Leaving it at 1.00 would
  /// overstate every margin reported from then on, and the error compounds
  /// with each delivery rather than washing out.
  ///
  /// A zero on the line is missing information, not a statement that the goods
  /// were free, so it leaves the existing cost alone. With nothing on the
  /// shelf to average against, the new price is simply the price.
  Future<void> _rollForwardCost(
    String itemId,
    int arriving,
    double unitCost,
  ) async {
    if (arriving <= 0 || unitCost <= 0) return;

    final item = await inventory.requireItem(itemId);
    final held = item.quantity;

    final next = held <= 0
        ? unitCost
        : ((held * item.unitCost) + (arriving * unitCost)) / (held + arriving);

    await (db.update(db.items)..where((t) => t.id.equals(itemId))).write(
      ItemsCompanion(
        unitCost: Value(next),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Sales orders
  // ------------------------------------------------------------------

  Future<List<SalesOrder>> salesOrders({String? status, int limit = 200}) {
    final query = db.select(db.salesOrders);
    if (status != null && status.isNotEmpty) {
      query.where((t) => t.status.equals(status));
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<({SalesOrder order, List<SalesOrderLine> lines})> salesOrder(
    String id,
  ) async {
    final row = await (db.select(
      db.salesOrders,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw ApiError.notFound;
    return (order: row, lines: await _salesOrderLines(id));
  }

  Future<List<SalesOrderLine>> _salesOrderLines(String id) =>
      (db.select(db.salesOrderLines)
            ..where((t) => t.orderId.equals(id))
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  /// Saves a sales order. Committing to sell does not move stock — the
  /// invoice or receipt raised against it does.
  Future<({SalesOrder order, List<SalesOrderLine> lines})> saveSalesOrder({
    required SalesOrdersCompanion header,
    required List<SalesOrderLinesCompanion> lines,
  }) async {
    return db.transaction(() async {
      final now = DateTime.now().toUtc();
      final id = idOrNew(header.id);

      final existing = await (db.select(
        db.salesOrders,
      )..where((t) => t.id.equals(id))).getSingleOrNull();

      if (existing == null) {
        await db
            .into(db.salesOrders)
            .insert(
              header.copyWith(
                id: Value(id),
                reference: Value(
                  header.reference.present && header.reference.value.isNotEmpty
                      ? header.reference.value
                      : await _nextReference('sales_order', 'SO-'),
                ),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      } else {
        await (db.update(db.salesOrders)..where((t) => t.id.equals(id))).write(
          header.copyWith(
            id: const Value.absent(),
            createdAt: const Value.absent(),
            updatedAt: Value(now),
          ),
        );
      }

      await (db.delete(
        db.salesOrderLines,
      )..where((t) => t.orderId.equals(id))).go();

      var position = 0;
      for (final line in lines) {
        await db
            .into(db.salesOrderLines)
            .insert(
              line.copyWith(
                // Present-but-empty is how a new line arrives: the route fills the
                // field in because the companion requires it, and only the service
                // knows whether this is an insert. Treating that as an id gives
                // every new line the same one.
                id: Value(
                  line.id.present && line.id.value.isNotEmpty
                      ? line.id.value
                      : newId(),
                ),
                orderId: Value(id),
                position: Value(position++),
              ),
            );
      }

      return (
        order: await (db.select(
          db.salesOrders,
        )..where((t) => t.id.equals(id))).getSingle(),
        lines: await _salesOrderLines(id),
      );
    });
  }

  /// Despatches goods against a sales order: stock out, and the line's
  /// fulfilled count moves up by what actually went.
  ///
  /// The mirror of [receiveGoods], with one extra constraint. A delivery can
  /// only be limited by what was ordered; a despatch is also limited by what
  /// is on the shelf, and the shelf is shared — another device may have sold
  /// the last of it since this order was opened. Each line is therefore
  /// clamped twice, and the caller is told what actually left rather than what
  /// it asked for.
  Future<({SalesOrder order, List<SalesOrderLine> lines})> despatchGoods({
    required String orderId,
    required Map<String, int> sentByLineId,
    required String actorId,
    String location = InventoryService.unassigned,
  }) async {
    return db.transaction(() async {
      final order = await (db.select(
        db.salesOrders,
      )..where((t) => t.id.equals(orderId))).getSingleOrNull();
      if (order == null) throw ApiError.notFound;

      if (order.status == 'cancelled') {
        throw ApiError.badRequest(
          'Order ${order.reference} was cancelled; nothing can be sent '
          'against it.',
        );
      }

      final lines = await _salesOrderLines(orderId);
      final byId = {for (final line in lines) line.id: line};

      for (final entry in sentByLineId.entries) {
        final line = byId[entry.key];
        if (line == null) {
          throw ApiError.badRequest('No line ${entry.key} on this order.');
        }
        if (entry.value <= 0) continue;

        final outstanding = line.quantityOrdered - line.quantityFulfilled;
        final item = await inventory.requireItem(line.itemId);
        // Whichever runs out first: the order, or the shelf.
        final quantity = [
          entry.value,
          outstanding,
          item.quantity,
        ].reduce((a, b) => a < b ? a : b);
        if (quantity <= 0) continue;

        await inventory.adjustStock(
          itemId: line.itemId,
          delta: -quantity,
          kind: 'sale',
          actorId: actorId,
          location: location,
          note: 'Despatched on ${order.reference}',
          documentId: orderId,
        );

        await (db.update(
          db.salesOrderLines,
        )..where((t) => t.id.equals(line.id))).write(
          SalesOrderLinesCompanion(
            quantityFulfilled: Value(line.quantityFulfilled + quantity),
            // Banked at despatch, not read back later: profit reporting has
            // to reflect what the stock cost when it left.
            costOfGoods: Value(line.costOfGoods + quantity * item.unitCost),
          ),
        );
      }

      final updated = await _salesOrderLines(orderId);
      final complete = updated.every(
        (line) => line.quantityFulfilled >= line.quantityOrdered,
      );
      final now = DateTime.now().toUtc();

      await (db.update(
        db.salesOrders,
      )..where((t) => t.id.equals(orderId))).write(
        SalesOrdersCompanion(
          status: Value(complete ? 'fulfilled' : 'partial'),
          closedAt: complete ? Value(now) : const Value.absent(),
          updatedAt: Value(now),
        ),
      );

      return (
        order: await (db.select(
          db.salesOrders,
        )..where((t) => t.id.equals(orderId))).getSingle(),
        lines: updated,
      );
    });
  }

  // ------------------------------------------------------------------
  // Transfers
  // ------------------------------------------------------------------

  Future<List<Transfer>> transfers({int limit = 200}) =>
      (db.select(db.transfers)
            ..orderBy([
              (t) =>
                  OrderingTerm(expression: t.movedAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();

  Future<({Transfer transfer, List<TransferLine> lines})> transfer(
    String id,
  ) async {
    final row = await (db.select(
      db.transfers,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw ApiError.notFound;
    final lines =
        await (db.select(db.transferLines)
              ..where((t) => t.transferId.equals(id))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
    return (transfer: row, lines: lines);
  }

  // ------------------------------------------------------------------
  // Stock effects
  // ------------------------------------------------------------------

  /// Moves stock for a document, once.
  ///
  /// Whether it has already been applied is answered by asking for movements
  /// carrying this document's id, rather than by a flag on the row. A retried
  /// save is then simply a no-op, instead of a second deduction nobody
  /// notices until the shelf disagrees with the screen.
  Future<void> _applyDocumentStock({
    required String documentId,
    required String kind,
    required String actorId,
    required String note,
    required List<({String itemId, int quantity})> lines,
    required int direction,
  }) async {
    if (await _hasMovements(documentId)) return;

    for (final line in lines) {
      if (line.quantity <= 0) continue;
      await inventory.adjustStock(
        itemId: line.itemId,
        delta: direction * line.quantity,
        kind: kind,
        actorId: actorId,
        note: note,
        documentId: documentId,
      );
    }
  }

  /// Puts back exactly what a document took, read from its own movements.
  ///
  /// Derived from what actually happened rather than recomputed from the
  /// lines, because the lines may have been edited since — and the stock owed
  /// back is what left, not what the document currently says.
  Future<void> _reverseDocumentStock({
    required String documentId,
    required String actorId,
    required String note,
    required String kind,
  }) async {
    final applied = await (db.select(
      db.movements,
    )..where((t) => t.documentId.equals(documentId))).get();

    // Only the original effect, not an earlier reversal of it.
    final net = <String, int>{};
    for (final movement in applied) {
      net[movement.itemId] =
          (net[movement.itemId] ?? 0) + (movement.after - movement.before);
    }

    for (final entry in net.entries) {
      if (entry.value == 0) continue;
      await inventory.adjustStock(
        itemId: entry.key,
        delta: -entry.value,
        kind: kind,
        actorId: actorId,
        note: note,
        documentId: documentId,
      );
    }
  }

  Future<bool> _hasMovements(String documentId) async {
    final row =
        await (db.select(db.movements)
              ..where((t) => t.documentId.equals(documentId))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Per-document-type counters, stored beside the workspace settings.
  ///
  /// Allocated inside the caller's transaction, so two people raising an
  /// invoice at the same moment cannot be handed the same number — the unique
  /// index on `reference` is the backstop if they somehow are.
  Future<String> _nextReference(String kind, String prefix) async {
    const keyPrefix = 'sequence.';
    final key = '$keyPrefix$kind';
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(key))).getSingleOrNull();

    final next = (int.tryParse(row?.value ?? '') ?? 0) + 1;
    await db
        .into(db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(key: key, value: '$next'),
        );

    return '$prefix${next.toString().padLeft(4, '0')}';
  }
}
