/// Internal max-heap over the caller's existing retained sort entries.
/// The maximum entry is the last/worst row in final output order. No second
/// backing list, eager capacity allocation, or SQL value evaluation is used.
final class BoundedSortHeap<T> {
  BoundedSortHeap(this.entries, this.compare) {
    for (var i = entries.length ~/ 2 - 1; i >= 0; i--) {
      _down(i);
    }
  }
  final List<T> entries;
  final int Function(T, T) compare;
  T get worst => entries.first;

  T removeWorst() {
    final result = entries.first;
    final last = entries.removeLast();
    if (entries.isNotEmpty) {
      entries[0] = last;
      _down(0);
    }
    return result;
  }

  void add(T entry) {
    entries.add(entry);
    var slot = entries.length - 1;
    while (slot > 0) {
      final parent = (slot - 1) ~/ 2;
      if (compare(entries[parent], entry) >= 0) break;
      entries[slot] = entries[parent];
      slot = parent;
    }
    entries[slot] = entry;
  }

  void _down(int slot) {
    final entry = entries[slot];
    while (slot * 2 + 1 < entries.length) {
      var child = slot * 2 + 1;
      if (child + 1 < entries.length &&
          compare(entries[child + 1], entries[child]) > 0) {
        child++;
      }
      if (compare(entry, entries[child]) >= 0) break;
      entries[slot] = entries[child];
      slot = child;
    }
    entries[slot] = entry;
  }
}
