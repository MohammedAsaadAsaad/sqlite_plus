import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/record_codec.dart';
import '../format/record_encoder.dart';

/// Inserts index records into an existing index btree.
///
/// A null result leaves [image] unchanged. Overflow cells, auto-vacuum, and
/// reserved bytes stay on the full rebuild path. Records are ordered by
/// [compare], which must be the same order the index was built with.
abstract final class IndexPagePatch {
  static Uint8List? insert(
    Uint8List image,
    int root,
    List<List<Object?>> records,
    int Function(List<Object?>, List<Object?>) compare,
  ) {
    if (records.isEmpty) return image;
    if (root <= 1) return null;
    final pages = _IndexPages.tryOpen(image);
    if (pages == null || root > pages.length) return null;
    final sorted = [...records]..sort(compare);
    for (var i = 1; i < sorted.length; i++) {
      if (compare(sorted[i - 1], sorted[i]) == 0) return null;
    }
    final empty = pages.isEmptyLeaf(root);
    if (empty) {
      final cells = <Uint8List>[];
      for (final record in sorted) {
        final cell = pages.encode(record);
        if (cell == null) return null;
        cells.add(cell);
      }
      if (!pages.build(root, cells)) return null;
    } else {
      for (final record in sorted) {
        if (!pages.insert(root, record, compare)) return null;
      }
    }
    pages.touch();
    return pages.assemble();
  }
}

final class _Promote {
  _Promote(this.key, this.right);
  final Uint8List key;
  final int right;
}

final class _Outcome {
  _Outcome.absorbed()
      : promoted = null,
        failed = false;
  _Outcome.up(this.promoted) : failed = false;
  _Outcome.fail()
      : promoted = null,
        failed = true;
  final _Promote? promoted;
  final bool failed;
}

final class _IndexPages {
  _IndexPages(this.pages, this.pageSize, this.encoding);
  final List<Uint8List> pages;
  final int pageSize;
  final int encoding;
  final Set<int> _copied = {};

  int get length => pages.length;

  static _IndexPages? tryOpen(Uint8List image) {
    DatabaseHeader header;
    try {
      header = DatabaseHeader.decode(image);
    } on FormatException {
      return null;
    }
    if (header.reservedBytes != 0 ||
        header.largestRootPage != 0 ||
        header.pageSize < 512 ||
        image.length != header.databaseSize * header.pageSize) {
      return null;
    }
    final size = header.pageSize;
    return _IndexPages([
      for (var offset = 0; offset < image.length; offset += size)
        Uint8List.sublistView(image, offset, offset + size)
    ], size, header.textEncoding);
  }

  Uint8List bytes(int number) => pages[number - 1];

  Uint8List cow(int number) {
    if (_copied.add(number)) {
      pages[number - 1] = Uint8List.fromList(pages[number - 1]);
    }
    return pages[number - 1];
  }

  int? allocate() {
    if (pages.length >= 0x7ffffffe) return null;
    pages.add(Uint8List(pageSize));
    _copied.add(pages.length);
    return pages.length;
  }

  int? type(int number) {
    if (number < 1 || number > pages.length) return null;
    return pages[number - 1][0];
  }

  bool isEmptyLeaf(int number) {
    if (type(number) != 10) return false;
    return ByteData.sublistView(pages[number - 1]).getUint16(3) == 0;
  }

  int get _maxLocal => ((pageSize - 12) * 64 ~/ 255) - 23;

  Uint8List? encode(List<Object?> record) {
    try {
      final payload = RecordEncoder.encode(record, encoding: encoding);
      if (payload.length > _maxLocal) return null;
      final prefix = RecordEncoder.varint(BigInt.from(payload.length));
      final cell = Uint8List(prefix.length + payload.length);
      cell.setRange(0, prefix.length, prefix);
      cell.setRange(prefix.length, cell.length, payload);
      return cell;
    } on Object {
      return null;
    }
  }

  List<Object?>? decode(Uint8List cell) {
    try {
      final reader = SqliteByteReader(cell);
      final size = reader.varint();
      if (size != BigInt.from(cell.length - reader.offset)) return null;
      if (size > BigInt.from(_maxLocal)) return null;
      return RecordCodec.decode(Uint8List.sublistView(cell, reader.offset),
          encoding: encoding);
    } on FormatException {
      return null;
    }
  }

  bool build(int root, List<Uint8List> cells) {
    if (cells.fold<int>(8, (sum, cell) => sum + cell.length + 2) <= pageSize) {
      return _write(root, cells, 10, null);
    }
    final children = <int>[];
    final keys = <Uint8List>[];
    var begin = 0;
    while (begin < cells.length) {
      var end = begin;
      var used = 8;
      while (end < cells.length && used + cells[end].length + 2 <= pageSize) {
        used += cells[end].length + 2;
        end++;
      }
      if (end == begin) return false;
      if (end < cells.length && end == cells.length - 1) end--;
      if (end <= begin) return false;
      final number = allocate();
      if (number == null ||
          !_write(number, cells.sublist(begin, end), 10, null)) {
        return false;
      }
      children.add(number);
      if (end < cells.length) {
        keys.add(cells[end]);
        begin = end + 1;
      } else {
        begin = end;
      }
    }
    if (children.length != keys.length + 1) return false;
    while (true) {
      if (keys.fold<int>(12, (sum, cell) => sum + cell.length + 6) <=
          pageSize) {
        return _write(
            root,
            [
              for (var i = 0; i < keys.length; i++)
                _interior(children[i], keys[i])
            ],
            2,
            children.last);
      }
      final nextChildren = <int>[];
      final nextKeys = <Uint8List>[];
      var start = 0;
      while (start < children.length) {
        var end = start + 1;
        var used = 12;
        while (end < children.length &&
            used + keys[end - 1].length + 6 <= pageSize) {
          used += keys[end - 1].length + 6;
          end++;
        }
        if (end < children.length && end == children.length - 1) end--;
        if (end <= start) return false;
        final number = allocate();
        if (number == null) return false;
        if (!_write(
            number,
            [
              for (var i = start; i < end - 1; i++)
                _interior(children[i], keys[i])
            ],
            2,
            children[end - 1])) {
          return false;
        }
        nextChildren.add(number);
        if (end < children.length) {
          nextKeys.add(keys[end - 1]);
          start = end;
        } else {
          start = end;
        }
      }
      if (nextChildren.length >= children.length) return false;
      children
        ..clear()
        ..addAll(nextChildren);
      keys
        ..clear()
        ..addAll(nextKeys);
      if (children.length != keys.length + 1) return false;
    }
  }

  bool insert(
    int root,
    List<Object?> record,
    int Function(List<Object?>, List<Object?>) compare,
  ) {
    final outcome = _insert(root, record, compare, <int>{});
    if (outcome.failed) return false;
    final promoted = outcome.promoted;
    if (promoted == null) return true;
    return _lift(root, promoted);
  }

  bool _lift(int root, _Promote promoted) {
    final saved = Uint8List.fromList(bytes(root));
    final moved = allocate();
    if (moved == null) return false;
    pages[moved - 1] = saved;
    _copied.add(moved);
    return _write(root, [_interior(moved, promoted.key)], 2, promoted.right);
  }

  _Outcome _insert(
    int page,
    List<Object?> record,
    int Function(List<Object?>, List<Object?>) compare,
    Set<int> seen,
  ) {
    if (!seen.add(page) || seen.length > 64) return _Outcome.fail();
    final kind = type(page);
    if (kind == 10) return _insertLeaf(page, record, compare);
    if (kind == 2) return _insertInterior(page, record, compare, seen);
    return _Outcome.fail();
  }

  _Outcome _insertLeaf(
    int page,
    List<Object?> record,
    int Function(List<Object?>, List<Object?>) compare,
  ) {
    final cells = _leafCells(page);
    if (cells == null) return _Outcome.fail();
    var index = cells.length;
    for (var i = 0; i < cells.length; i++) {
      final values = decode(cells[i]);
      if (values == null) return _Outcome.fail();
      final order = compare(record, values);
      if (order == 0) return _Outcome.fail();
      if (order < 0) {
        index = i;
        break;
      }
    }
    final cell = encode(record);
    if (cell == null) return _Outcome.fail();
    final combined = [...cells]..insert(index, cell);
    if (_fits(10, combined)) {
      if (!_write(page, combined, 10, null)) return _Outcome.fail();
      return _Outcome.absorbed();
    }
    if (combined.length < 3) return _Outcome.fail();
    var middle = combined.length ~/ 2;
    if (middle < 1) middle = 1;
    if (middle > combined.length - 2) middle = combined.length - 2;
    final right = allocate();
    if (right == null ||
        !_write(page, combined.sublist(0, middle), 10, null) ||
        !_write(right, combined.sublist(middle + 1), 10, null)) {
      return _Outcome.fail();
    }
    return _Outcome.up(_Promote(combined[middle], right));
  }

  _Outcome _insertInterior(
    int page,
    List<Object?> record,
    int Function(List<Object?>, List<Object?>) compare,
    Set<int> seen,
  ) {
    final cells = _interiorCells(page);
    final right = _right(page);
    if (cells == null || right == null) return _Outcome.fail();
    var child = right;
    var position = cells.length;
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].length < 5) return _Outcome.fail();
      final values = decode(Uint8List.sublistView(cells[i], 4));
      if (values == null) return _Outcome.fail();
      final order = compare(record, values);
      if (order == 0) return _Outcome.fail();
      if (order < 0) {
        child = ByteData.sublistView(cells[i]).getUint32(0);
        position = i;
        break;
      }
    }
    if (child < 1 || child > pages.length) return _Outcome.fail();
    final below = _insert(child, record, compare, seen);
    if (below.failed) return below;
    final promoted = below.promoted;
    if (promoted == null) return _Outcome.absorbed();
    final next = [...cells];
    var nextRight = right;
    final separator = _interior(child, promoted.key);
    if (position == cells.length) {
      next.add(separator);
      nextRight = promoted.right;
    } else {
      next.insert(position, separator);
      final old = Uint8List.fromList(next[position + 1]);
      ByteData.sublistView(old).setUint32(0, promoted.right);
      next[position + 1] = old;
    }
    if (_fits(2, next)) {
      if (!_write(page, next, 2, nextRight)) return _Outcome.fail();
      return _Outcome.absorbed();
    }
    if (next.length < 3) return _Outcome.fail();
    var middle = next.length ~/ 2;
    if (middle < 1) middle = 1;
    if (middle > next.length - 2) middle = next.length - 2;
    final middleCell = next[middle];
    if (middleCell.length < 5) return _Outcome.fail();
    final sibling = allocate();
    if (sibling == null ||
        !_write(page, next.sublist(0, middle), 2,
            ByteData.sublistView(middleCell).getUint32(0)) ||
        !_write(sibling, next.sublist(middle + 1), 2, nextRight)) {
      return _Outcome.fail();
    }
    return _Outcome.up(_Promote(Uint8List.sublistView(middleCell, 4), sibling));
  }

  List<Uint8List>? _leafCells(int number) {
    if (type(number) != 10) return null;
    final data = ByteData.sublistView(pages[number - 1]);
    final count = data.getUint16(3);
    final cells = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final offset = data.getUint16(8 + i * 2);
      final cell = _slice(number, offset, leaf: true);
      if (cell == null) return null;
      cells.add(cell);
    }
    return cells;
  }

  List<Uint8List>? _interiorCells(int number) {
    if (type(number) != 2) return null;
    final data = ByteData.sublistView(pages[number - 1]);
    final count = data.getUint16(3);
    final cells = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final offset = data.getUint16(12 + i * 2);
      final cell = _slice(number, offset, leaf: false);
      if (cell == null) return null;
      cells.add(cell);
    }
    return cells;
  }

  Uint8List? _slice(int number, int offset, {required bool leaf}) {
    if (offset < (leaf ? 8 : 12) || offset >= pageSize) return null;
    try {
      final reader = SqliteByteReader(pages[number - 1],
          offset: leaf ? offset : offset + 4);
      final size = reader.varint();
      if (size > BigInt.from(_maxLocal)) return null;
      final end = reader.offset + size.toInt();
      if (end > pageSize) return null;
      return Uint8List.fromList(pages[number - 1].sublist(offset, end));
    } on FormatException {
      return null;
    }
  }

  int? _right(int number) {
    if (type(number) != 2) return null;
    final child = ByteData.sublistView(pages[number - 1]).getUint32(8);
    if (child < 1 || child > pages.length) return null;
    return child;
  }

  bool _fits(int kind, List<Uint8List> cells) {
    final header = kind == 10 ? 8 : 12;
    var total = header;
    for (final cell in cells) {
      total += cell.length + 2;
    }
    return total <= pageSize;
  }

  Uint8List _interior(int child, Uint8List key) {
    final bytes = Uint8List(key.length + 4);
    ByteData.sublistView(bytes).setUint32(0, child);
    bytes.setRange(4, bytes.length, key);
    return bytes;
  }

  bool _write(int number, List<Uint8List> cells, int kind, int? right) {
    final header = kind == 10 ? 8 : 12;
    if (!_fits(kind, cells)) return false;
    final page = cow(number);
    page.fillRange(0, pageSize, 0);
    final data = ByteData.sublistView(page);
    page[0] = kind;
    data.setUint16(3, cells.length);
    if (right != null) data.setUint32(8, right);
    var end = pageSize;
    for (var i = 0; i < cells.length; i++) {
      end -= cells[i].length;
      if (end < header + 2 * cells.length) return false;
      page.setRange(end, end + cells[i].length, cells[i]);
      data.setUint16(header + i * 2, end);
    }
    data.setUint16(5, end == 65536 ? 0 : end);
    return true;
  }

  void touch() {
    final page = cow(1);
    final data = ByteData.sublistView(page);
    final counter = (data.getUint32(24) + 1) & 0xffffffff;
    data.setUint32(24, counter);
    data.setUint32(92, counter);
    data.setUint32(28, pages.length);
  }

  Uint8List assemble() {
    final image = Uint8List(pages.length * pageSize);
    for (var i = 0; i < pages.length; i++) {
      image.setRange(i * pageSize, (i + 1) * pageSize, pages[i]);
    }
    return image;
  }
}
