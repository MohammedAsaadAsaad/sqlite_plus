import 'dart:math';
import 'package:sqlite_plus/src/sql/bounded_sort_heap.dart';
import 'package:test/test.dart';

void main() {
  test('heap retains earliest ties and matches a sorted reference across K',
      () {
    final random = Random(71240);
    for (final k in [1, 2, 31, 32, 33, 100, 1024]) {
      final input = [for (var i = 0; i < 3000; i++) (random.nextInt(27), i)];
      int compare((int, int) a, (int, int) b) {
        final key = a.$1.compareTo(b.$1);
        return key != 0 ? key : a.$2.compareTo(b.$2);
      }

      final retained = input.take(k).toList();
      final heap = BoundedSortHeap(retained, compare);
      for (final row in input.skip(k)) {
        if (compare(row, heap.worst) < 0) {
          heap.removeWorst();
          heap.add(row);
        }
        expect(retained.length, k);
      }
      retained.sort(compare);
      input.sort(compare);
      expect(retained, input.take(k).toList(), reason: 'K=$k');
    }
  });
  test('empty/single heaps and bounded comparison work', () {
    var comparisons = 0;
    final entries = <int>[];
    final heap = BoundedSortHeap(entries, (a, b) {
      comparisons++;
      return a.compareTo(b);
    });
    for (var i = 9999; i >= 0; i--) {
      if (entries.length == 128) heap.removeWorst();
      heap.add(i);
    }
    expect(entries.length, 128);
    expect(comparisons, lessThan(300000));
    entries.sort();
    expect(entries, List.generate(128, (i) => i));
    final single = BoundedSortHeap(<int>[5], (a, b) => a.compareTo(b));
    expect(single.removeWorst(), 5);
    single.add(2);
    expect(single.worst, 2);
  });
}
