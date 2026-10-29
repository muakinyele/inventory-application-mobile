import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/snapshot.dart';
import '../../state/inventory_controller.dart';

/// Fetches the document collections a screen needs, the first time it is shown.
///
/// Documents used to arrive at sign-in — all five lists with every line —
/// before the dashboard, which reads none of them, could draw. This is the
/// other half of moving that off the startup path: a screen declares what it
/// shows and waits for that alone, so opening Receipts does not pay for
/// purchase orders.
///
/// The wait is only ever paid ONCE per collection per session. A second visit
/// finds it loaded and builds immediately, with no flash of a spinner — which
/// is why [InventoryController.documentsReady] is checked before any frame is
/// spent on one.
class DocumentGate extends StatefulWidget {
  const DocumentGate({super.key, required this.need, required this.builder});

  /// What this screen reads. Keep it to what is actually shown.
  final Set<DocumentSet> need;

  final WidgetBuilder builder;

  @override
  State<DocumentGate> createState() => _DocumentGateState();
}

class _DocumentGateState extends State<DocumentGate> {
  /// Whether this branch was on screen last time dependencies changed.
  ///
  /// The navigation shell is an `IndexedStack`: leaving a tab does not dispose
  /// it, it only goes offstage, and coming back does not run `initState`
  /// again. So a first attempt that failed would otherwise be the only attempt
  /// this screen ever made — a spinner for the rest of the session, which is
  /// exactly what a stale fetch looked like. Returning to the tab is a retry.
  bool _wasOnStage = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: `ensureDocuments` notifies listeners when it
    // finishes, and notifying during a build is what throws.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `TickerMode` is what the shell switches when a branch becomes the
    // visible one, which makes it the signal for "this screen is being looked
    // at now" that an always-mounted widget otherwise has no way to see.
    final onStage = TickerMode.valuesOf(context).enabled;
    final returning = onStage && !_wasOnStage;
    _wasOnStage = onStage;
    if (returning) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(DocumentGate old) {
    super.didUpdateWidget(old);
    if (!setEquals(old.need, widget.need)) _load();
  }

  void _load() {
    if (!mounted) return;
    final controller = context.read<InventoryController>();
    if (controller.documentsReady(widget.need)) return;
    controller.ensureDocuments(widget.need);
  }

  @override
  Widget build(BuildContext context) {
    // Watched, so the gate opens as soon as the fetch lands.
    final controller = context.watch<InventoryController>();

    if (controller.documentsReady(widget.need)) return widget.builder(context);

    final failure = controller.documentError(widget.need);
    final loading = controller.documentsLoading(widget.need);
    if (failure != null && !loading) {
      return _DocumentLoadFailed(error: failure, onRetry: _load);
    }

    // Not there, not failed, and nothing fetching it: forgotten by a reload
    // after this gate had already finished waiting. Nothing else would ask
    // again, so this spun for ever with everything it needed fetched once.
    // Asked once more; a failure shows the error above, so it cannot loop.
    if (!loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// Shown when the fetch did not land.
///
/// An endless spinner is the worst of both: it says nothing about what went
/// wrong and offers nothing to do about it, while looking like progress.
class _DocumentLoadFailed extends StatelessWidget {
  const _DocumentLoadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 40,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  'Could not load this page',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
