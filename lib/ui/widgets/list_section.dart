import 'package:flutter/material.dart';

import '../../core/design.dart';
import 'empty_state.dart';
import 'pagination.dart';

/// A searchable, paged list — the body of a list page.
///
/// EXISTS BECAUSE SEVEN PAGES HAD NONE OF IT. Purchase orders, sales orders,
/// suppliers, customers, transfers, activity and alerts each rendered their
/// whole list into a scrolling column with no search, no filter and no sense
/// of how long the list was. The two pages that did have a search had each
/// built their own.
///
/// It lives inside `PageBody`, which is already a [ListView], so this must not
/// scroll or expand: it lays its rows out in a column and lets the page
/// scroll. That is affordable precisely because it only ever builds one page
/// of rows.
///
/// Filters stay with the PAGE, because they are page-specific — a status, a
/// date range, a category. The page filters [rows] itself and passes
/// [filterSignature]; when that changes, the cursor rewinds. Search is here
/// because every page wanted the same one.
class ListSection<T> extends StatefulWidget {
  const ListSection({
    super.key,
    required this.rows,
    required this.itemBuilder,
    required this.searchHint,
    required this.matches,
    required this.unit,
    required this.emptyState,
    this.filters = const [],
    this.filterSignature,
    this.totalRows,
    this.nothingMatchesTitle = 'Nothing matches',
    this.nothingMatchesBody =
        'Try a different search term, or clear the filters.',
    this.onClearFilters,
    this.gap = Insets.md,
  });

  /// The rows to show, already narrowed by whatever filters the page owns.
  final List<T> rows;
  final Widget Function(BuildContext context, T row) itemBuilder;
  final String searchHint;

  /// Whether a row matches the typed query, which arrives already lower-cased
  /// and trimmed so each page only has to say which fields are searchable.
  final bool Function(T row, String query) matches;

  /// Plural noun for a row: "invoices", "suppliers".
  final String unit;

  /// Shown when the page has nothing at all — a different situation from a
  /// search matching nothing, and one that deserves different words.
  final Widget emptyState;

  /// Controls the page owns, rendered under the search field.
  final List<Widget> filters;

  /// Anything that changes when the page's own filters change. The cursor
  /// rewinds when it does, because page 7 of the old result set means nothing
  /// in the new one.
  final Object? filterSignature;

  /// How many rows there are before the page's filters, so the bar can say
  /// "of 312 matching (1,204 in total)". Defaults to [rows].
  final int? totalRows;

  final String nothingMatchesTitle;
  final String nothingMatchesBody;

  /// Clears the page's own filters as well as the search box.
  final VoidCallback? onClearFilters;

  final double gap;

  @override
  State<ListSection<T>> createState() => _ListSectionState<T>();
}

class _ListSectionState<T> extends State<ListSection<T>> {
  final _search = TextEditingController();
  PageCursor _cursor = const PageCursor();

  @override
  void didUpdateWidget(ListSection<T> old) {
    super.didUpdateWidget(old);
    // A filter the page owns has changed under us. Same reasoning as typing a
    // search: the reader wants the top of the new result, not page 7 of it.
    if (old.filterSignature != widget.filterSignature) {
      _cursor = _cursor.withPage(0);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refine(VoidCallback change) {
    setState(() {
      change();
      _cursor = _cursor.withPage(0);
    });
  }

  List<T> get _visible {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.rows;
    return [
      for (final row in widget.rows)
        if (widget.matches(row, query)) row,
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Nothing at all: say so, and do not offer a search over an empty list.
    if (widget.rows.isEmpty && (widget.totalRows ?? 0) == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: Insets.section),
        child: widget.emptyState,
      );
    }

    final visible = _visible;
    final cursor = _cursor.clamped(visible.length);
    final page = cursor.slice(visible);
    final total = widget.totalRows ?? widget.rows.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchField(
          controller: _search,
          hintText: widget.searchHint,
          onChanged: (_) => _refine(() {}),
        ),
        for (final filter in widget.filters) ...[
          const SizedBox(height: Insets.sm),
          filter,
        ],
        const SizedBox(height: Insets.lg),
        if (page.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xl),
            child: EmptyState(
              icon: Icons.search_off,
              title: widget.nothingMatchesTitle,
              body: widget.nothingMatchesBody,
              action: OutlinedButton(
                onPressed: () => _refine(() {
                  _search.clear();
                  widget.onClearFilters?.call();
                }),
                child: const Text('Clear search'),
              ),
            ),
          )
        else
          for (final row in page) ...[
            widget.itemBuilder(context, row),
            SizedBox(height: widget.gap),
          ],
        PaginationBar(
          cursor: cursor,
          total: visible.length,
          unit: widget.unit,
          unfilteredTotal: total,
          filtered: visible.length != total,
          onCursor: (next) => setState(() => _cursor = next),
        ),
      ],
    );
  }
}
