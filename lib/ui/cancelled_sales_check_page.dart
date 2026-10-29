import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design.dart';
import '../core/palette.dart';
import '../data/auth_api.dart';
import '../models/cancelled_sale_issue.dart';
import '../state/inventory_controller.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';
import 'widgets/section_card.dart';

/// Finds sales cancelled before cancelling returned stock, and repairs them.
///
/// The scan is read-only. A repair returns the stock the sale sent and
/// cancels its unpaid invoices; one with a payment against it is shown but
/// left alone until the payment is refunded.
class CancelledSalesCheckPage extends StatefulWidget {
  const CancelledSalesCheckPage({super.key});

  @override
  State<CancelledSalesCheckPage> createState() =>
      _CancelledSalesCheckPageState();
}

class _CancelledSalesCheckPageState extends State<CancelledSalesCheckPage> {
  List<CancelledSaleIssue>? _issues;
  String? _error;
  bool _scanning = false;
  bool _fixingAll = false;
  final _fixing = <String>{};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final issues = await context
          .read<InventoryController>()
          .scanCancelledSales();
      if (!mounted) return;
      setState(() => _issues = issues);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is AuthApiException
            ? error.message
            : 'The check could not be run. Try again.',
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _fix(CancelledSaleIssue issue) async {
    setState(() => _fixing.add(issue.salesOrderId));
    final refused = await context
        .read<InventoryController>()
        .repairCancelledSale(issue.salesOrderId);
    if (!mounted) return;
    setState(() => _fixing.remove(issue.salesOrderId));
    await showAppMessage(
      context,
      refused ?? '${issue.salesOrderReference} repaired',
      tone: refused == null ? MessageTone.success : MessageTone.failure,
    );
    if (mounted) await _scan();
  }

  Future<void> _fixAll() async {
    final fixable = _issues?.where((i) => i.fixable).length ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Repair all'),
        content: Text(
          'Repair $fixable ${fixable == 1 ? 'sale' : 'sales'}? Their stock '
          'goes back on the shelf and their unpaid invoices are cancelled. '
          'Sales with a payment are left alone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Repair all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _fixingAll = true);
    String message;
    var tone = MessageTone.success;
    try {
      final result = await context
          .read<InventoryController>()
          .repairAllCancelledSales();
      message = 'Repaired ${result.repaired.length}.';
      if (result.skipped.isNotEmpty) {
        tone = MessageTone.warning;
        message +=
            ' Left ${result.skipped.length}: '
            '${result.skipped.map((s) => '${s.reference} (${s.reason})').join('; ')}';
      }
    } catch (error) {
      tone = MessageTone.failure;
      message = error is AuthApiException
          ? error.message
          : 'The repair could not be run, so nothing was changed.';
    }
    if (!mounted) return;
    setState(() => _fixingAll = false);
    await showAppMessage(context, message, tone: tone);
    if (mounted) await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final issues = _issues;
    final fixable = issues?.where((i) => i.fixable).length ?? 0;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Insets.pageNarrow,
            Insets.xl,
            Insets.pageNarrow,
            Insets.section,
          ),
          children: [
            PageHeader(
              title: 'Cancelled sales check',
              subtitle: 'Sales cancelled without their stock coming back',
              showBack: true,
              actions: [
                IconButton(
                  tooltip: 'Scan again',
                  onPressed: _scanning || _fixingAll ? null : _scan,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: Insets.xl),
            if (_error != null)
              EmptyState(
                icon: Icons.error_outline,
                title: 'The check did not run',
                body: _error!,
                action: FilledButton(
                  onPressed: _scan,
                  child: const Text('Try again'),
                ),
              )
            else if (issues == null)
              const Padding(
                padding: EdgeInsets.all(Insets.section),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (issues.isEmpty)
              const EmptyState(
                icon: Icons.check_circle_outline,
                title: 'Nothing to repair',
                body:
                    'Every cancelled sale has its stock back and no live '
                    'invoice.',
              )
            else ...[
              Text(
                '${issues.length} ${issues.length == 1 ? 'sale needs' : 'sales need'} '
                'attention. Repairing one puts its stock back and cancels its '
                'unpaid invoices.',
                style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
              ),
              const SizedBox(height: Insets.lg),
              if (fixable > 0) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _fixingAll ? null : _fixAll,
                    icon: _fixingAll
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.build_outlined, size: 18),
                    label: Text('Repair all ($fixable)'),
                  ),
                ),
                const SizedBox(height: Insets.lg),
              ],
              for (final issue in issues) ...[
                _IssueCard(
                  issue: issue,
                  busy: _fixingAll || _fixing.contains(issue.salesOrderId),
                  onFix: () => _fix(issue),
                ),
                const SizedBox(height: Insets.md),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({
    required this.issue,
    required this.busy,
    required this.onFix,
  });

  final CancelledSaleIssue issue;
  final bool busy;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final line = TextStyle(fontSize: 13.5, color: p.ink);

    return SectionCard(
      title: issue.customerName.isEmpty
          ? issue.salesOrderReference
          : '${issue.salesOrderReference} · ${issue.customerName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final out in issue.stockOut)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Text(
                '${out.quantity} × ${out.itemName} still out of stock',
                style: line,
              ),
            ),
          for (final invoice in issue.liveInvoices)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Text(
                'Invoice ${invoice.reference} still live'
                '${invoice.amountPaid > 0 ? ', has a payment' : ''}',
                style: line,
              ),
            ),
          const SizedBox(height: Insets.sm),
          if (issue.fixable)
            OutlinedButton.icon(
              onPressed: busy ? null : onFix,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.build_outlined, size: 18),
              label: const Text('Repair'),
            )
          else
            Text(
              'Paid against (${issue.paidBy.join(', ')}). Refund the payment '
              'first, then repair.',
              style: TextStyle(fontSize: 13, color: p.critical),
            ),
        ],
      ),
    );
  }
}
