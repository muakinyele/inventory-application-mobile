import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/ui/widgets/pagination.dart';

void main() {
  group('PageCursor', () {
    test('slices the page it points at', () {
      final rows = List.generate(312, (i) => i);
      const cursor = PageCursor(page: 1, size: 50);

      final page = cursor.slice(rows);

      expect(page.first, 50);
      expect(page.last, 99);
      expect(page, hasLength(50));
    });

    test('the last page is short rather than padded', () {
      final rows = List.generate(312, (i) => i);
      const cursor = PageCursor(page: 6, size: 50);

      expect(cursor.slice(rows), hasLength(12));
      expect(cursor.slice(rows).last, 311);
    });

    test('an empty list slices to nothing rather than throwing', () {
      const cursor = PageCursor(page: 4, size: 50);
      expect(cursor.slice(<int>[]), isEmpty);
    });

    test('a page beyond the end slices to nothing, not an error', () {
      // Belt and braces: `clamped` is what should prevent this, but a slice
      // that throws turns a stale cursor into a red screen.
      final rows = List.generate(10, (i) => i);
      const cursor = PageCursor(page: 9, size: 50);
      expect(cursor.slice(rows), isEmpty);
    });

    // THE ONE THAT BREAKS PAGINATED LISTS. Someone on page 9 types a search
    // that matches three rows. Without this the page renders empty and reads
    // as "no results" for a search that found three.
    test('a filter that shrinks the list pulls the cursor back', () {
      const cursor = PageCursor(page: 8, size: 50);

      final corrected = cursor.clamped(3);

      expect(corrected.page, 0);
      expect(corrected.slice(List.generate(3, (i) => i)), hasLength(3));
    });

    test('clamping lands on the last real page, not always the first', () {
      const cursor = PageCursor(page: 20, size: 25);
      expect(cursor.clamped(60).page, 2, reason: '60 rows at 25 is pages 0–2');
    });

    test('an empty result clamps to the first page', () {
      const cursor = PageCursor(page: 7, size: 50);
      expect(cursor.clamped(0).page, 0);
    });

    test('a cursor already in range is left alone', () {
      const cursor = PageCursor(page: 2, size: 25);
      expect(cursor.clamped(300).page, 2);
    });

    test('changing the page size keeps the reader where they were', () {
      // Page 4 at 25 rows starts at row 100. At 100 rows that is page 1, so
      // row 100 is still on screen — switching 25 → 100 should show more of
      // the same place, not jump somewhere unrelated.
      const cursor = PageCursor(page: 4, size: 25);

      final resized = cursor.withSize(100);

      expect(resized.size, 100);
      expect(resized.page, 1);
      expect(resized.firstIndex, 100);
    });

    test('shrinking the page size also keeps the first row in view', () {
      const cursor = PageCursor(page: 1, size: 100);

      final resized = cursor.withSize(25);

      expect(resized.page, 4);
      expect(resized.firstIndex, 100);
    });

    test('the default page size is one of the offered options', () {
      expect(pageSizeOptions, contains(defaultPageSize));
    });
  });
}
