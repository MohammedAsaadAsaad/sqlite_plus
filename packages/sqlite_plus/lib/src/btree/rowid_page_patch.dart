import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/record_codec.dart';
import '../format/record_encoder.dart';

/// Right-edge edits of one ordinary rowid table inside an existing image.
///
/// A null result means the caller must rebuild the image. The input bytes are
/// left unchanged. Overflow pages, freeblock reuse, descending keys, and
/// interior pages that cannot take one more child are left to that rebuild.
abstract final class RowidPagePatch {
  static Map<String, int>? schemaRoots(Uint8List image) {
    final header = DatabaseHeader.decode(image);
    if (image.length < header.pageSize || header.reservedBytes != 0) {
      return null;
    }
    final page = Uint8List.sublistView(image, 0, header.pageSize);
    if (page[100] != 13) return null;
    final cells = _cells(page, 1, header.pageSize);
    if (cells == null) return null;
    final roots = <String, int>{};
    for (final cell in cells) {
      final values = _values(page, cell, header);
      if (values == null || values.length < 4) return null;
      final type = values[0];
      final name = values[1];
      final root = values[3];
      if (type is! String || name is! String || root is! BigInt) return null;
      if (root < BigInt.zero || root > BigInt.from(0x7fffffff)) return null;
      roots[name.toLowerCase()] = root.toInt();
    }
    return roots;
  }

  /// Appends [rowId] when it is greater than every key already in the tree.
  static Uint8List? append(
      Uint8List image, int root, BigInt rowId, List<Object?> values) {
    if (root < 1 || rowId < -(BigInt.one << 63) || rowId >= BigInt.one << 63) {
      return null;
    }
    final pages = _Pages.tryOpen(image);
    if (pages == null) return null;
    final cell = pages.tableCell(rowId, values);
    if (cell == null) return null;
    final leaf = pages.rightmost(root);
    if (leaf == null || !_isLeaf(pages, leaf)) return null;
    final count = pages.count(leaf);
    if (count == null) return null;
    if (count > 0) {
      final last = pages.cellBounds(leaf, count - 1);
      if (last == null) return null;
      final max = _rowid(pages.bytes(leaf), last.start, pages.pageSize);
      if (max == null || rowId <= max) return null;
    }
    final existing = pages.leafCells(leaf);
    if (existing == null) return null;
    if (pages.writeLeaf(leaf, [...existing, cell])) {
      pages.touch();
      return pages.assemble();
    }
    return _splitRight(pages, root, leaf, cell, count);
  }

  /// Replaces the payload of [rowId]. The rowid itself stays in place.
  static Uint8List? replace(
      Uint8List image, int root, BigInt rowId, List<Object?> values) {
    if (root < 1) return null;
    final pages = _Pages.tryOpen(image);
    if (pages == null) return null;
    final found = pages.find(root, rowId);
    if (found == null) return null;
    final cell = pages.tableCell(rowId, values);
    if (cell == null) return null;
    final bounds = pages.cellBounds(found.leaf, found.index);
    if (bounds == null) return null;
    if (cell.length == bounds.length) {
      pages.cow(found.leaf).setRange(bounds.start, bounds.end, cell);
      pages.touch();
      return pages.assemble();
    }
    final cells = pages.leafCells(found.leaf);
    if (cells == null) return null;
    cells[found.index] = cell;
    if (!pages.writeLeaf(found.leaf, cells)) return null;
    pages.touch();
    return pages.assemble();
  }

  /// Removes [rowId]. An emptied non-root leaf, or a deleted separator key,
  /// returns null so the tree can be rebuilt instead of left unbalanced.
  static Uint8List? delete(Uint8List image, int root, BigInt rowId) {
    if (root < 1) return null;
    final pages = _Pages.tryOpen(image);
    if (pages == null) return null;
    final found = pages.find(root, rowId);
    if (found == null) return null;
    if (found.separator == rowId) return null;
    final cells = pages.leafCells(found.leaf);
    if (cells == null || found.index >= cells.length) return null;
    cells.removeAt(found.index);
    if (cells.isEmpty && found.leaf != root) {
      if (!pages.unlinkEmpty(root, found.leaf)) return null;
      pages.touch();
      return pages.assemble();
    }
    if (!pages.writeLeaf(found.leaf, cells)) return null;
    if (found.separator == rowId) {
      final max = _rowid(cells.last, 0, cells.last.length);
      if (max == null || !pages.replaceSeparator(root, rowId, max)) {
        return null;
      }
    }
    pages.touch();
    return pages.assemble();
  }

  /// Adds [deltas] into decoded record fields when every leaf can be rewritten
  /// without splitting. Keys are indexes in the stored record.
  static Uint8List? addColumns(
      Uint8List image, int root, Map<int, BigInt> deltas) {
    if (root < 1 || deltas.isEmpty) return null;
    final inplace = _Pages.tryOpen(image);
    if (inplace != null && _addInPlace(inplace, root, deltas, <int>{})) {
      inplace.touch();
      return inplace.assemble();
    }
    final pages = _Pages.tryOpen(image);
    if (pages == null) return null;
    if (!_addLeaves(pages, root, deltas, <int>{})) return null;
    pages.touch();
    return pages.assemble();
  }

  /// Empties [root] and drops pages past it when no other catalog root uses them.
  static Uint8List? clearRoot(Uint8List image, int root) {
    if (root < 2) return null;
    final roots = schemaRoots(image);
    final pages = _Pages.tryOpen(image);
    if (roots == null || pages == null || root > pages.pages.length) {
      return null;
    }
    for (final other in roots.values) {
      if (other > root) return null;
    }
    final leaf = Uint8List(pages.pageSize);
    leaf[0] = 13;
    ByteData.sublistView(leaf)
        .setUint16(5, pages.pageSize == 65536 ? 0 : pages.pageSize);
    pages.pages[root - 1] = leaf;
    pages._copied.add(root);
    if (pages.pages.length > root) {
      pages.pages.removeRange(root, pages.pages.length);
    }
    final header = pages.cow(1);
    final data = ByteData.sublistView(header);
    data.setUint32(32, 0);
    data.setUint32(36, 0);
    pages.touch();
    return pages.assemble();
  }

  static bool _addInPlace(
      _Pages pages, int number, Map<int, BigInt> deltas, Set<int> seen) {
    if (!seen.add(number)) return false;
    final type = pages.type(number);
    if (type == 13) {
      final preview = pages.leafCells(number);
      if (preview == null) return false;
      final fits =
          preview.every((cell) => _bumpCell(Uint8List.fromList(cell), deltas));
      if (!fits) return _rewriteLeaf(pages, number, deltas);
      pages.cow(number);
      final cells = pages.leafCells(number);
      if (cells == null) return false;
      for (final cell in cells) {
        if (!_bumpCell(cell, deltas)) return false;
      }
      return true;
    }
    if (type != 5) return false;
    final children = pages.children(number);
    if (children == null) return false;
    for (final child in children) {
      if (!_addInPlace(pages, child, deltas, seen)) return false;
    }
    return true;
  }

  static bool _bumpCell(Uint8List cell, Map<int, BigInt> deltas) {
    try {
      final reader = SqliteByteReader(cell);
      final headerSize = reader.varint().toInt();
      if (headerSize < reader.offset || headerSize > cell.length) return false;
      final serials = <int>[];
      while (reader.offset < headerSize) {
        final serial = reader.varint();
        if (serial > BigInt.from(0x7fffffff)) return false;
        serials.add(serial.toInt());
      }
      if (reader.offset != headerSize) return false;
      var body = headerSize;
      for (var slot = 0; slot < serials.length; slot++) {
        final width = _serialWidth(serials[slot]);
        if (width < 0 || body + width > cell.length) return false;
        final delta = deltas[slot];
        if (delta != null &&
            delta != BigInt.zero &&
            !_storeInteger(cell, body, serials[slot], width, delta)) {
          return false;
        }
        body += width;
      }
      return body == cell.length;
    } on FormatException {
      return false;
    }
  }

  static int _serialWidth(int serial) {
    const fixed = [0, 1, 2, 3, 4, 6, 8, 8, 0, 0];
    if (serial < 0) return -1;
    if (serial < fixed.length) return fixed[serial];
    if (serial >= 12) return (serial - 12) ~/ 2;
    return -1;
  }

  static bool _storeInteger(
      Uint8List cell, int body, int serial, int width, BigInt delta) {
    if (serial < 1 || serial > 6) return false;
    var integer = BigInt.zero;
    for (var i = 0; i < width; i++) {
      integer = (integer << 8) | BigInt.from(cell[body + i]);
    }
    final next = integer.toSigned(width * 8) + delta;
    final bits = width * 8;
    final min = -(BigInt.one << (bits - 1));
    final max = (BigInt.one << (bits - 1)) - BigInt.one;
    if (next < min || next > max) return false;
    var unsigned = next.toUnsigned(bits);
    for (var i = width - 1; i >= 0; i--) {
      cell[body + i] = (unsigned & BigInt.from(255)).toInt();
      unsigned >>= 8;
    }
    return true;
  }

  static bool _rewriteLeaf(_Pages pages, int number, Map<int, BigInt> deltas) {
    final cells = pages.leafCells(number);
    if (cells == null) return false;
    for (var i = 0; i < cells.length; i++) {
      final rowid = _rowid(cells[i], 0, cells[i].length);
      final decoded = _payloadValues(cells[i], pages.encoding);
      if (rowid == null || decoded == null) return false;
      final values = List<Object?>.of(decoded);
      for (final entry in deltas.entries) {
        if (entry.key < 0 || entry.key >= values.length) return false;
        final value = values[entry.key];
        if (value == null) continue;
        if (value is! BigInt) return false;
        values[entry.key] = value + entry.value;
      }
      final cell = pages.tableCell(rowid, values);
      if (cell == null) return false;
      cells[i] = cell;
    }
    return pages.writeLeaf(number, cells);
  }

  static bool _addLeaves(
      _Pages pages, int number, Map<int, BigInt> deltas, Set<int> seen) {
    if (!seen.add(number)) return false;
    final type = pages.type(number);
    if (type == 13) return _rewriteLeaf(pages, number, deltas);
    if (type != 5) return false;
    final children = pages.children(number);
    if (children == null) return false;
    for (final child in children) {
      if (!_addLeaves(pages, child, deltas, seen)) return false;
    }
    return true;
  }

  static Uint8List? _splitRight(
      _Pages pages, int root, int leaf, Uint8List cell, int count) {
    final fresh = pages.allocate();
    if (fresh == null || !pages.writeLeaf(fresh, [cell])) return null;
    final parent = pages.parentOfRightmost(root, leaf);
    if (parent == null && leaf != root) return null;
    if (count < 1) return null;
    final last = pages.cellBounds(leaf, count - 1);
    if (last == null) return null;
    final max = _rowid(pages.bytes(leaf), last.start, pages.pageSize);
    if (max == null) return null;
    final separator = pages.interiorCell(leaf, max);
    if (separator == null) return null;
    if (parent == null) {
      final old = pages.leafCells(leaf);
      if (old == null) return null;
      final left = pages.allocate();
      if (left == null || !pages.writeLeaf(left, old)) return null;
      final moved = pages.interiorCell(left, max);
      if (moved == null || !pages.writeInterior(leaf, [moved], fresh)) {
        return null;
      }
    } else {
      final cells = pages.interiorCells(parent);
      if (cells == null) return null;
      cells.add(separator);
      if (!pages.writeInterior(parent, cells, fresh)) return null;
    }
    pages.touch();
    return pages.assemble();
  }

  static bool _isLeaf(_Pages pages, int number) => pages.type(number) == 13;

  static List<(int, int)>? _cells(Uint8List page, int number, int pageSize) {
    final start = number == 1 ? 100 : 0;
    if (page[start] != 13 && page[start] != 5) return null;
    final data = ByteData.sublistView(page);
    final count = data.getUint16(start + 3);
    final header = page[start] == 13 ? 8 : 12;
    final offsets = <(int, int)>[];
    for (var i = 0; i < count; i++) {
      final offset = data.getUint16(start + header + i * 2);
      if (offset < start + header || offset >= pageSize) return null;
      offsets.add((offset, 0));
    }
    return offsets;
  }

  static List<Object?>? _values(
      Uint8List page, (int, int) cell, DatabaseHeader header) {
    final rowid = _rowid(page, cell.$1, header.pageSize);
    if (rowid == null) return null;
    return _payloadValues(
        Uint8List.sublistView(page, cell.$1), header.textEncoding);
  }

  static List<Object?>? _payloadValues(Uint8List cell, int encoding) {
    try {
      final reader = SqliteByteReader(cell);
      final size = reader.varint();
      reader.varint();
      if (size > BigInt.from(cell.length - reader.offset)) return null;
      final length = size.toInt();
      final payload =
          Uint8List.sublistView(cell, reader.offset, reader.offset + length);
      return RecordCodec.decode(payload, encoding: encoding);
    } on FormatException {
      return null;
    }
  }

  static BigInt? _rowid(Uint8List bytes, int offset, int end) {
    try {
      final reader = SqliteByteReader(bytes, offset: offset, end: end);
      reader.varint();
      return reader.varint().toSigned(64);
    } on FormatException {
      return null;
    }
  }
}

final class _Found {
  _Found(this.leaf, this.index, this.separator);
  final int leaf;
  final int index;
  final BigInt? separator;
}

final class _Bounds {
  _Bounds(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start;
}

final class _Pages {
  _Pages(this.pages, this.pageSize, this.encoding);
  final List<Uint8List> pages;
  final int pageSize;
  final int encoding;
  final Set<int> _copied = {};

  static _Pages? tryOpen(Uint8List image) {
    DatabaseHeader header;
    try {
      header = DatabaseHeader.decode(image);
    } on FormatException {
      return null;
    }
    if (header.reservedBytes != 0 ||
        header.largestRootPage != 0 ||
        header.pageSize == 0 ||
        image.length != header.databaseSize * header.pageSize) {
      return null;
    }
    final size = header.pageSize;
    return _Pages([
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
    if (pages.length >= 0x7fffffff) return null;
    pages.add(Uint8List(pageSize));
    _copied.add(pages.length);
    return pages.length;
  }

  int? type(int number) {
    if (number < 1 || number > pages.length) return null;
    final start = number == 1 ? 100 : 0;
    return pages[number - 1][start];
  }

  int? count(int number) {
    final kind = type(number);
    if (kind != 13 && kind != 5) return null;
    final start = number == 1 ? 100 : 0;
    return ByteData.sublistView(pages[number - 1]).getUint16(start + 3);
  }

  int? rightmost(int root) {
    var number = root;
    final seen = <int>{};
    while (true) {
      if (!seen.add(number)) return null;
      final kind = type(number);
      if (kind == 13) return number;
      if (kind != 5) return null;
      final start = number == 1 ? 100 : 0;
      final child =
          ByteData.sublistView(pages[number - 1]).getUint32(start + 8);
      if (child < 1 || child > pages.length) return null;
      number = child;
    }
  }

  int? parentOfRightmost(int root, int leaf) {
    var number = root;
    int? parent;
    final seen = <int>{};
    while (number != leaf) {
      if (!seen.add(number)) return null;
      if (type(number) != 5) return null;
      parent = number;
      final start = number == 1 ? 100 : 0;
      number = ByteData.sublistView(pages[number - 1]).getUint32(start + 8);
      if (number < 1 || number > pages.length) return null;
    }
    return parent;
  }

  bool fits(int number, int cellLength) {
    final kind = type(number);
    if (kind != 13 && kind != 5) return false;
    final start = number == 1 ? 100 : 0;
    final data = ByteData.sublistView(pages[number - 1]);
    final cells = data.getUint16(start + 3);
    final header = kind == 13 ? 8 : 12;
    final raw = data.getUint16(start + 5);
    final content = raw == 0 ? 65536 : raw;
    final pointerEnd = start + header + 2 * cells;
    return content - pointerEnd >= cellLength + 2;
  }

  bool insertLeaf(int number, int index, Uint8List cell) {
    final cells = leafCells(number);
    if (cells == null || index != cells.length) return false;
    cells.add(cell);
    return writeLeaf(number, cells);
  }

  _Bounds? cellBounds(int number, int index) {
    final kind = type(number);
    if (kind != 13) return null;
    final start = number == 1 ? 100 : 0;
    final data = ByteData.sublistView(pages[number - 1]);
    final cells = data.getUint16(start + 3);
    if (index < 0 || index >= cells) return null;
    final offset = data.getUint16(start + 8 + index * 2);
    final length = _cellLength(pages[number - 1], offset);
    if (length == null) return null;
    return _Bounds(offset, offset + length);
  }

  List<Uint8List>? leafCells(int number) {
    final total = count(number);
    if (total == null || type(number) != 13) return null;
    final page = pages[number - 1];
    final cells = <Uint8List>[];
    for (var i = 0; i < total; i++) {
      final bounds = cellBounds(number, i);
      if (bounds == null) return null;
      cells.add(Uint8List.sublistView(page, bounds.start, bounds.end));
    }
    return cells;
  }

  List<Uint8List>? interiorCells(int number) {
    if (type(number) != 5) return null;
    final start = number == 1 ? 100 : 0;
    final page = pages[number - 1];
    final data = ByteData.sublistView(page);
    final cells = data.getUint16(start + 3);
    final result = <Uint8List>[];
    for (var i = 0; i < cells; i++) {
      final offset = data.getUint16(start + 12 + i * 2);
      final length = _interiorLength(page, offset);
      if (length == null) return null;
      result.add(Uint8List.sublistView(page, offset, offset + length));
    }
    return result;
  }

  List<int>? children(int number) {
    if (type(number) != 5) return null;
    final start = number == 1 ? 100 : 0;
    final page = pages[number - 1];
    final data = ByteData.sublistView(page);
    final cells = data.getUint16(start + 3);
    final result = <int>[];
    for (var i = 0; i < cells; i++) {
      final offset = data.getUint16(start + 12 + i * 2);
      if (offset + 4 > pageSize) return null;
      result.add(data.getUint32(offset));
    }
    final right = data.getUint32(start + 8);
    if (right < 1 || right > pages.length) return null;
    result.add(right);
    return result;
  }

  _Found? find(int root, BigInt key) {
    var number = root;
    BigInt? separator;
    final seen = <int>{};
    while (true) {
      if (!seen.add(number)) return null;
      final kind = type(number);
      if (kind == 13) {
        final total = count(number);
        if (total == null) return null;
        final page = pages[number - 1];
        for (var i = 0; i < total; i++) {
          final bounds = cellBounds(number, i);
          if (bounds == null) return null;
          final rowid = RowidPagePatch._rowid(page, bounds.start, pageSize);
          if (rowid == null) return null;
          if (rowid == key) return _Found(number, i, separator);
        }
        return null;
      }
      if (kind != 5) return null;
      final start = number == 1 ? 100 : 0;
      final page = pages[number - 1];
      final data = ByteData.sublistView(page);
      final cells = data.getUint16(start + 3);
      var child = data.getUint32(start + 8);
      separator = null;
      for (var i = 0; i < cells; i++) {
        final offset = data.getUint16(start + 12 + i * 2);
        if (offset + 4 > pageSize) return null;
        final left = data.getUint32(offset);
        final rowid = _interiorKey(page, offset + 4);
        if (rowid == null) return null;
        if (key <= rowid) {
          child = left;
          separator = rowid;
          break;
        }
      }
      if (child < 1 || child > pages.length) return null;
      number = child;
    }
  }

  Uint8List? tableCell(BigInt rowId, List<Object?> values) {
    try {
      final payload = RecordEncoder.encode(values, encoding: encoding);
      if (payload.length > pageSize - 35) return null;
      final prefix = [
        ...RecordEncoder.varint(BigInt.from(payload.length)),
        ...RecordEncoder.varint(rowId.toUnsigned(64))
      ];
      return Uint8List.fromList([...prefix, ...payload]);
    } on Object {
      return null;
    }
  }

  Uint8List? interiorCell(int child, BigInt key) {
    try {
      final body = RecordEncoder.varint(key.toUnsigned(64));
      final cell = Uint8List(4 + body.length);
      ByteData.sublistView(cell).setUint32(0, child);
      cell.setRange(4, cell.length, body);
      return cell;
    } on Object {
      return null;
    }
  }

  bool writeLeaf(int number, List<Uint8List> cells) =>
      _write(number, cells, 13, null);

  bool writeInterior(int number, List<Uint8List> cells, int right) =>
      _write(number, cells, 5, right);

  bool _write(int number, List<Uint8List> cells, int kind, int? right) {
    final start = number == 1 ? 100 : 0;
    final header = kind == 13 ? 8 : 12;
    var total = header;
    for (final cell in cells) {
      total += cell.length + 2;
    }
    if (start + total > pageSize) return false;
    final page = cow(number);
    page.fillRange(start, pageSize, 0);
    final data = ByteData.sublistView(page);
    page[start] = kind;
    data.setUint16(start + 3, cells.length);
    if (right != null) data.setUint32(start + 8, right);
    var end = pageSize;
    for (var i = 0; i < cells.length; i++) {
      end -= cells[i].length;
      if (end < start + header + 2 * cells.length) return false;
      page.setRange(end, end + cells[i].length, cells[i]);
      data.setUint16(start + header + i * 2, end);
    }
    data.setUint16(start + 5, end == 65536 ? 0 : end);
    return true;
  }

  bool unlinkEmpty(int root, int leaf) {
    final edge = _findEdge(root, leaf, <int>{});
    if (edge == null) return false;
    final parent = edge.$1;
    final cells = interiorCells(parent);
    if (cells == null) return false;
    final start = parent == 1 ? 100 : 0;
    final right = ByteData.sublistView(pages[parent - 1]).getUint32(start + 8);
    if (edge.$3) {
      if (cells.isEmpty) {
        if (parent != root || parent == 1) return false;
        final empty = Uint8List(pageSize);
        empty[0] = 13;
        ByteData.sublistView(empty)
            .setUint16(5, pageSize == 65536 ? 0 : pageSize);
        pages[parent - 1] = empty;
        _copied.add(parent);
        return _freePage(leaf);
      }
      final last = cells.removeLast();
      if (last.length < 4) return false;
      final left = ByteData.sublistView(last).getUint32(0);
      if (!writeInterior(parent, cells, left)) return false;
    } else {
      if (edge.$2 < 0 || edge.$2 >= cells.length) return false;
      cells.removeAt(edge.$2);
      if (!writeInterior(parent, cells, right)) return false;
    }
    if (count(parent) == 0 && !_collapse(root, parent)) return false;
    return _freePage(leaf);
  }

  bool replaceSeparator(int root, BigInt oldKey, BigInt newKey) =>
      _replaceKey(root, oldKey, newKey, <int>{});

  bool _replaceKey(int number, BigInt oldKey, BigInt newKey, Set<int> seen) {
    if (!seen.add(number) || type(number) != 5) return false;
    final cells = interiorCells(number);
    final kids = children(number);
    if (cells == null || kids == null) return false;
    final start = number == 1 ? 100 : 0;
    final right = ByteData.sublistView(pages[number - 1]).getUint32(start + 8);
    for (var i = 0; i < cells.length; i++) {
      if (_cellKey(cells[i]) != oldKey) continue;
      final child = ByteData.sublistView(cells[i]).getUint32(0);
      final replacement = interiorCell(child, newKey);
      if (replacement == null) return false;
      cells[i] = replacement;
      return writeInterior(number, cells, right);
    }
    for (final child in kids) {
      if (type(child) == 5 && _replaceKey(child, oldKey, newKey, seen)) {
        return true;
      }
    }
    return false;
  }

  bool _collapse(int root, int parent) {
    final start = parent == 1 ? 100 : 0;
    final child = ByteData.sublistView(pages[parent - 1]).getUint32(start + 8);
    if (child < 1 || child > pages.length || child == parent) return false;
    if (parent == root) {
      if (parent == 1) return false;
      pages[parent - 1] = Uint8List.fromList(pages[child - 1]);
      _copied.add(parent);
      return _freePage(child);
    }
    final edge = _findEdge(root, parent, <int>{});
    if (edge == null || !_retarget(edge, child)) return false;
    return _freePage(parent);
  }

  bool _retarget((int, int, bool) edge, int child) {
    final parent = edge.$1;
    final cells = interiorCells(parent);
    if (cells == null) return false;
    final start = parent == 1 ? 100 : 0;
    final right = ByteData.sublistView(pages[parent - 1]).getUint32(start + 8);
    if (edge.$3) return writeInterior(parent, cells, child);
    if (edge.$2 < 0 || edge.$2 >= cells.length) return false;
    final key = _cellKey(cells[edge.$2]);
    if (key == null) return false;
    final replacement = interiorCell(child, key);
    if (replacement == null) return false;
    cells[edge.$2] = replacement;
    return writeInterior(parent, cells, right);
  }

  bool _freePage(int number) {
    if (number < 2 || number > pages.length) return false;
    final page = cow(number);
    page.fillRange(0, pageSize, 0);
    final trunk = ByteData.sublistView(page);
    final header = ByteData.sublistView(cow(1));
    trunk.setUint32(0, header.getUint32(32));
    trunk.setUint32(4, 0);
    header.setUint32(32, number);
    header.setUint32(36, header.getUint32(36) + 1);
    return true;
  }

  (int, int, bool)? _findEdge(int node, int target, Set<int> seen) {
    if (!seen.add(node) || type(node) != 5) return null;
    final start = node == 1 ? 100 : 0;
    final page = pages[node - 1];
    final data = ByteData.sublistView(page);
    final cells = data.getUint16(start + 3);
    for (var i = 0; i < cells; i++) {
      final offset = data.getUint16(start + 12 + i * 2);
      if (offset + 4 > pageSize) return null;
      if (data.getUint32(offset) == target) return (node, i, false);
    }
    final right = data.getUint32(start + 8);
    if (right == target) return (node, -1, true);
    for (var i = 0; i < cells; i++) {
      final offset = data.getUint16(start + 12 + i * 2);
      final found = _findEdge(data.getUint32(offset), target, seen);
      if (found != null) return found;
    }
    return _findEdge(right, target, seen);
  }

  BigInt? _cellKey(Uint8List cell) {
    if (cell.length < 5) return null;
    return _interiorKey(cell, 4);
  }

  void touch() {
    final page = cow(1);
    final data = ByteData.sublistView(page);
    final counter = data.getUint32(24) + 1;
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

  static int? _cellLength(Uint8List page, int offset) {
    try {
      final reader = SqliteByteReader(page, offset: offset);
      final size = reader.varint();
      reader.varint();
      if (size > BigInt.from(page.length - 35)) return null;
      final end = reader.offset + size.toInt();
      if (end > page.length) return null;
      return end - offset;
    } on FormatException {
      return null;
    }
  }

  static int? _interiorLength(Uint8List page, int offset) {
    try {
      final reader = SqliteByteReader(page, offset: offset + 4);
      reader.varint();
      return reader.offset - offset;
    } on FormatException {
      return null;
    }
  }

  static BigInt? _interiorKey(Uint8List page, int offset) {
    try {
      return SqliteByteReader(page, offset: offset).varint().toSigned(64);
    } on FormatException {
      return null;
    }
  }
}
