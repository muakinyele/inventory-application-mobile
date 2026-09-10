import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// The audit trail (§20).
///
/// Read-only — there is no edit or delete affordance here, and no endpoint
/// behind one either. A trail you can tidy up from the screen that displays it
/// is not evidence of anything.
class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key});

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  static const _pageSize = 50;

  final _search = TextEditingController();
  Timer? _debounce;

  List<AuditEntry>? _entries;
  List<String> _actions = const [];
  int _total = 0;
  int _offset = 0;
  String? _action;
  DateTimeRange? _range;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadActions();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadActions() async {
    try {
      final actions = await context.read<AuthController>().api.auditActions();
      if (mounted) setState(() => _actions = actions);
    } on AuthApiException {
      // The filter simply stays empty; the log itself still loads.
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final page = await context.read<AuthController>().api.auditLogs(
        action: _action,
        search: _search.text,
        from: _range?.start,
        to: _range?.end,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _entries = page.entries;
        _total = page.total;
        _error = null;
        _loading = false;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _offset = 0;
      _load();
    });
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _range,
    );
    if (picked == null) return;
    setState(() {
      _range = picked;
      _offset = 0;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.pageNarrow,
                Insets.xl,
                Insets.pageNarrow,
                0,
              ),
              child: PageHeader(
                title: 'Audit log',
                subtitle: _total == 1
                    ? '1 recorded event'
                    : '$_total recorded events',
              ),
            ),
            const SizedBox(height: Insets.lg),

            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.pageNarrow,
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: const InputDecoration(
                      hintText: 'Search by person, target or event',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                  const SizedBox(height: Insets.md),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _action,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Event type',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              child: Text('All events'),
                            ),
                            for (final action in _actions)
                              DropdownMenuItem<String?>(
                                value: action,
                                child: Text(
                                  AuditEntry(
                                    id: '',
                                    action: action,
                                    result: 'success',
                                    at: DateTime.now(),
                                  ).label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _action = value;
                              _offset = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      IconButton.filledTonal(
                        onPressed: _pickRange,
                        icon: const Icon(Icons.date_range_rounded),
                        tooltip: 'Filter by date',
                      ),
                      if (_range != null)
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _range = null;
                              _offset = 0;
                            });
                            _load();
                          },
                          icon: const Icon(Icons.clear_rounded),
                          tooltip: 'Clear date filter',
                        ),
                    ],
                  ),
                  if (_range != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${shortDay(_range!.start)} – '
                          '${shortDay(_range!.end)}',
                          style: TextStyle(color: p.inkSecondary, fontSize: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),

            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final p = context.palette;

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.pageNarrow),
        child: Column(
          children: [
            AuthNotice(message: _error!),
            const SizedBox(height: Insets.lg),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }

    if (_entries == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries!.isEmpty) {
      return const EmptyState(
        icon: Icons.history_rounded,
        title: 'Nothing recorded',
        body: 'No events match these filters.',
      );
    }

    final lastPage = _offset + _pageSize >= _total;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        Insets.pageNarrow,
        0,
        Insets.pageNarrow,
        Insets.section,
      ),
      itemCount: _entries!.length + 1,
      separatorBuilder: (_, _) => Divider(color: p.line, height: Insets.lg),
      itemBuilder: (context, index) {
        if (index == _entries!.length) {
          if (_total <= _pageSize) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: Insets.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _offset == 0 || _loading
                      ? null
                      : () {
                          setState(() => _offset -= _pageSize);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('Newer'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                  child: Text(
                    '${_offset + 1}–${_offset + _entries!.length} of $_total',
                    style: TextStyle(color: p.inkMuted, fontSize: 13),
                  ),
                ),
                TextButton.icon(
                  onPressed: lastPage || _loading
                      ? null
                      : () {
                          setState(() => _offset += _pageSize);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('Older'),
                ),
              ],
            ),
          );
        }
        return _AuditRow(entry: _entries![index]);
      },
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = entry.failed ? p.critical : p.ink;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          entry.failed
              ? Icons.error_outline_rounded
              : Icons.check_circle_outline_rounded,
          size: 18,
          color: entry.failed ? p.critical : p.goodText,
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.label,
                style: TextStyle(fontWeight: FontWeight.w600, color: colour),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  entry.actorEmail ?? 'System',
                  if (entry.targetLabel != null &&
                      entry.targetLabel != entry.actorEmail)
                    '→ ${entry.targetLabel}',
                ].join(' '),
                style: TextStyle(color: p.inkSecondary, fontSize: 13),
              ),
              if (entry.ipAddress != null)
                Text(
                  entry.ipAddress!,
                  style: TextStyle(color: p.inkMuted, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        Text(
          relativeTime(entry.at),
          style: TextStyle(color: p.inkMuted, fontSize: 12),
        ),
      ],
    );
  }
}
