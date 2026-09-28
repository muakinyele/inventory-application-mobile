import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';

/// How many rows a list page shows at once.
///
/// 25 first because it is the one that fits a phone without becoming a scroll
/// marathon; 100 and 200 are there for the person who would rather see the lot
/// and use the browser's own find.
const pageSizeOptions = <int>[25, 50, 100, 200];

const defaultPageSize = 50;

/// Where a list page is: which slice, of how many, at what size.
///
/// Held by the page rather than by this widget, because the page is what
/// filters — and a filter that drops the row count has to be able to pull the
/// cursor back to a page that still exists. [clamped] is that rule in one
/// place, so no page has to remember it.
class PageCursor {
  const PageCursor({this.page = 0, this.size = defaultPageSize});

  /// Zero-based.
  final int page;
  final int size;

  PageCursor withPage(int next) => PageCursor(page: next, size: size);

  /// Changing the size keeps the first row of the current page in view, which
  /// is what somebody switching 25 → 100 expects: the same place, more of it.
  PageCursor withSize(int next) =>
      PageCursor(page: (page * size) ~/ next, size: next);

  /// The cursor, corrected for a list of [total] rows.
  ///
  /// A search that cuts 400 rows to 3 while the reader is on page 9 has to
  /// land somewhere real; without this the page renders empty and looks like
  /// the search found nothing.
  PageCursor clamped(int total) {
    if (total <= 0) return withPage(0);
    final last = (total - 1) ~/ size;
    return page > last ? withPage(last) : this;
  }

  int get firstIndex => page * size;

  /// The slice of [rows] this cursor points at.
  List<T> slice<T>(List<T> rows) {
    if (rows.isEmpty) return const [];
    final start = firstIndex.clamp(0, rows.length);
    final end = (start + size).clamp(0, rows.length);
    return rows.sublist(start, end);
  }
}

/// The bar under a list: what is being shown, how much of it, and the way to
/// the rest.
///
/// Deliberately says "Showing 51–100 of 312" rather than only "Page 2 of 7".
/// The count is the part that matters — a list that silently held more than it
/// showed is the defect this exists for — and a reader should not have to
/// multiply to find out how much they are looking at.
class PaginationBar extends StatelessWidget {
  const PaginationBar({
    super.key,
    required this.cursor,
    required this.total,
    required this.onCursor,
    this.unit = 'items',
    this.filtered = false,
    this.unfilteredTotal,
  });

  final PageCursor cursor;

  /// Rows after filtering — what the reader is paging through.
  final int total;
  final ValueChanged<PageCursor> onCursor;

  /// Plural noun for the row, so the bar reads as English on every page.
  final String unit;

  /// Whether a search or filter is narrowing the list, which changes the
  /// sentence: how many matched, out of how many there are.
  final bool filtered;
  final int? unfilteredTotal;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pages = total <= 0 ? 1 : ((total - 1) ~/ cursor.size) + 1;
    final first = total == 0 ? 0 : cursor.firstIndex + 1;
    final last = total == 0
        ? 0
        : (cursor.firstIndex + cursor.size).clamp(0, total);

    final summary = total == 0
        ? 'No $unit'
        : filtered && unfilteredTotal != null && unfilteredTotal != total
        ? 'Showing ${number(first)}–${number(last)} of ${number(total)} '
              'matching $unit (${number(unfilteredTotal!)} in total)'
        : 'Showing ${number(first)}–${number(last)} of ${number(total)} $unit';

    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final controls = [
            _RowsPerPage(
              size: cursor.size,
              onChanged: (size) => onCursor(cursor.withSize(size)),
            ),
            if (pages > 1) ...[
              const SizedBox(width: Insets.md),
              _Stepper(
                page: cursor.page,
                pages: pages,
                onPage: (next) => onCursor(cursor.withPage(next)),
              ),
            ],
          ];

          final label = Text(
            summary,
            style: TextStyle(fontSize: 13, color: p.inkMuted),
          );

          // Stacked on a phone: the summary and the controls together are
          // wider than a narrow screen, and squeezing them makes the page
          // numbers unreadable rather than merely tight.
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: Insets.md),
                Row(children: controls),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: label),
              ...controls,
            ],
          );
        },
      ),
    );
  }
}

class _RowsPerPage extends StatelessWidget {
  const _RowsPerPage({required this.size, required this.onChanged});

  final int size;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Rows', style: TextStyle(fontSize: 13, color: p.inkMuted)),
        const SizedBox(width: Insets.sm),
        // A popup rather than a DropdownButton. This control sits at the
        // BOTTOM of a long page, and a dropdown opens a menu sized to the
        // viewport from where it stands — which at the foot of a tall list
        // has nowhere to go, and fails its own layout assertion rather than
        // flipping. A popup anchors to the button and opens whichever way it
        // fits.
        PopupMenuButton<int>(
          tooltip: 'Rows per page',
          initialValue: pageSizeOptions.contains(size) ? size : defaultPageSize,
          position: PopupMenuPosition.under,
          onSelected: onChanged,
          itemBuilder: (context) => [
            for (final option in pageSizeOptions)
              PopupMenuItem(value: option, child: Text('$option')),
          ],
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: Insets.md),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: p.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$size', style: TextStyle(fontSize: 13, color: p.ink)),
                const SizedBox(width: Insets.xs),
                Icon(Icons.arrow_drop_down, size: 18, color: p.inkMuted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.page,
    required this.pages,
    required this.onPage,
  });

  final int page;
  final int pages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          // Null rather than a dimmed button that does nothing: a disabled
          // control should not accept the tap in the first place.
          onPressed: page > 0 ? () => onPage(page - 1) : null,
          icon: const Icon(Icons.chevron_left, size: 20),
          tooltip: 'Previous page',
          visualDensity: VisualDensity.compact,
        ),
        Text(
          '${number(page + 1)} / ${number(pages)}',
          style: TextStyle(fontSize: 13, color: p.ink),
        ),
        IconButton(
          onPressed: page < pages - 1 ? () => onPage(page + 1) : null,
          icon: const Icon(Icons.chevron_right, size: 20),
          tooltip: 'Next page',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// A search field shaped like the rest of the app's controls.
///
/// Here rather than on each page because seven list pages had no search at
/// all, and the two that did had built their own.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search, size: 20),
        // Only when there is something to clear, so the field does not carry
        // a permanent button that usually does nothing.
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Clear search',
                onPressed: () {
                  controller.clear();
                  onChanged?.call('');
                },
              ),
        filled: true,
        fillColor: p.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: p.line),
        ),
      ),
    );
  }
}
