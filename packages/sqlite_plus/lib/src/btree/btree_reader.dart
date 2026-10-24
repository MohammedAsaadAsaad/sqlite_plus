import 'dart:math' as math;
import 'dart:typed_data';

import '../format/btree_page_header.dart';
import '../format/record_codec.dart';
import '../pager/read_only_pager.dart';

/// A physical record. INTEGER PRIMARY KEY aliases remain null in [values];
/// their value is [rowId]. Index records have no separate rowId.
final class BtreeRecord {
  BtreeRecord._(this.rowId, this.values);
  final BigInt? rowId;
  final List<Object?> values;
}

final class _PageTask {
  _PageTask(this.number, this.table, this.lower, this.upper);
  final int number;
  final bool table;
  final BigInt? lower;
  final BigInt? upper;
}

/// Iterative in-order traversal of rowid tables and index B-trees.
/// Traversal returns physical records; it does not apply SQL or collations.
final class BtreeReader {
  BtreeReader(this.pager,
      {this.maxPayloadBytes = 16 * 1024 * 1024, this.onPageRead}) {
    if (maxPayloadBytes < 1) throw RangeError.value(maxPayloadBytes);
  }
  final ReadOnlyPager pager;
  final void Function(int pageNumber)? onPageRead;
  Future<Uint8List> _readPage(int number) async {
    final result = await pager.readPage(number);
    onPageRead?.call(number);
    return result;
  }

  final int maxPayloadBytes;

  /// Descends separator keys to a single rowid without scanning other leaves.
  Future<BtreeRecord?> findRowid(int rootPage, BigInt key) async {
    final used = <int>{};
    var number = rootPage;
    BigInt? lower;
    BigInt? upper;
    while (true) {
      if (!used.add(number)) {
        throw const FormatException('Repeated search page');
      }
      final bytes = await _readPage(number);
      final header = BtreePageHeader.decode(bytes,
          database: pager.header, pageNumber: number);
      if (!header.isTable) {
        throw const FormatException('Rowid lookup requires a table B-tree');
      }
      var child = header.rightmostChild;
      var selected = false;
      BigInt? previous = lower;
      final inheritedUpper = upper;
      final ranges = <(int, int)>[];
      SqliteByteReader? match;
      BigInt? payload;
      for (final offset in header.cellOffsets) {
        final cell = SqliteByteReader(bytes,
            offset: offset, end: pager.header.usableSize);
        final left = header.isLeaf ? null : cell.uint32();
        final size = header.isLeaf ? cell.varint() : null;
        final rowid = cell.varint().toSigned(64);
        var end = cell.offset;
        if (size != null) {
          final usable = pager.header.usableSize;
          var local = size <= BigInt.from(usable - 35) ? size.toInt() : -1;
          if (local == -1) {
            final minimum = ((usable - 12) * 32 ~/ 255) - 23;
            local = minimum +
                ((size - BigInt.from(minimum)) % BigInt.from(usable - 4))
                    .toInt();
            if (local > usable - 35) local = minimum;
          }
          end += local + (size > BigInt.from(local) ? 4 : 0);
          if (end > usable) {
            throw const FormatException('Invalid search cell bounds');
          }
        }
        ranges.add((offset, end));

        if ((previous != null && rowid <= previous) ||
            (inheritedUpper != null && rowid > inheritedUpper)) {
          throw const FormatException('Invalid search separator order');
        }
        if (header.isLeaf && rowid == key) {
          match = cell;
          payload = size;
        }
        if (!header.isLeaf && !selected && key <= rowid) {
          child = left;
          upper = rowid;
          lower = previous;
          selected = true;
        }
        previous = rowid;
      }
      _validateRanges(bytes, header, ranges);
      if (header.isLeaf) {
        if (match == null) return null;
        final data =
            await _payload(match, payload!, tableLeaf: true, used: used);
        return BtreeRecord._(
            key, RecordCodec.decode(data, encoding: pager.header.textEncoding));
      }
      if (!selected) lower = previous;
      number = child!;
    }
  }

  Stream<BtreeRecord> scanTable(int rootPage) => _scan(rootPage, true);
  Stream<BtreeRecord> scanIndex(int rootPage) => _scan(rootPage, false);

  /// Visits branches that may contain keys whose sorted-prefix comparison is zero.
  /// [compare] must compare an index record with one fixed search prefix in the
  /// index's declared order. Unvisited branches are not corruption-validated.
  Stream<BtreeRecord> seekIndex(
          int rootPage, int Function(List<Object?>) compare) =>
      _scan(rootPage, false, compare);

  Stream<BtreeRecord> seekTable(int rootPage, int Function(BigInt) compare) =>
      _scan(rootPage, true, null, compare);

  Stream<BtreeRecord> _scan(int root, bool table,
      [int Function(List<Object?>)? compare,
      int Function(BigInt)? compareRowid]) async* {
    final selective = compare != null || compareRowid != null;
    final used = <int>{};
    final stack = <Object>[_PageTask(root, table, null, null)];
    BigInt? previous;
    while (stack.isNotEmpty) {
      final task = stack.removeLast();
      if (task is BtreeRecord) {
        final rowId = task.rowId;
        if (rowId != null) {
          if (previous != null && rowId <= previous) {
            throw const FormatException(
                'Table rowids are not strictly ordered');
          }
          previous = rowId;
        }
        yield task;
        continue;
      }
      final node = task as _PageTask;
      if (!used.add(node.number)) {
        throw const FormatException('Repeated B-tree or overflow page');
      }
      final bytes = await _readPage(node.number);
      final header = BtreePageHeader.decode(bytes,
          database: pager.header, pageNumber: node.number);
      if (header.isTable != node.table) {
        throw const FormatException('Mixed table/index B-tree');
      }
      final actions = <Object>[];
      final ranges = <(int, int)>[];
      var lower = node.lower;
      var priorComparison = -1;
      for (final offset in header.cellOffsets) {
        final cell = SqliteByteReader(bytes,
            offset: offset, end: pager.header.usableSize);
        final child = header.isLeaf ? null : cell.uint32();
        BigInt? rowId;
        List<Object?>? values;
        if (node.table && !header.isLeaf) {
          rowId = cell.varint().toSigned(64);
        } else {
          final payloadSize = cell.varint();
          if (node.table) rowId = cell.varint().toSigned(64);
          final payload = await _payload(cell, payloadSize,
              tableLeaf: node.table, used: used);
          values =
              RecordCodec.decode(payload, encoding: pager.header.textEncoding);
        }
        ranges.add((offset, cell.offset));
        if (rowId != null &&
            ((lower != null && rowId <= lower) ||
                (node.upper != null && rowId > node.upper!))) {
          throw const FormatException('Rowid outside B-tree separator bounds');
        }
        final comparison = compareRowid != null
            ? compareRowid(rowId!).sign
            : compare == null
                ? 0
                : compare(values!).sign;
        if (selective && comparison < priorComparison) {
          throw const FormatException('Index prefix out of order');
        }
        if (child != null &&
            (!selective || priorComparison <= 0 && comparison >= 0)) {
          actions.add(
              _PageTask(child, node.table, lower, node.table ? rowId : null));
        }
        if (values != null && comparison == 0) {
          actions.add(BtreeRecord._(rowId, values));
        }
        priorComparison = comparison;
        if (node.table) lower = rowId;
      }
      _validateRanges(bytes, header, ranges);
      if (!header.isLeaf && (!selective || priorComparison <= 0)) {
        actions.add(
            _PageTask(header.rightmostChild!, node.table, lower, node.upper));
      }
      stack.addAll(actions.reversed);
    }
  }

  void _validateRanges(
      Uint8List bytes, BtreePageHeader header, List<(int, int)> ranges) {
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) {
        throw const FormatException('Overlapping cells');
      }
    }
    var free = header.firstFreeblock;
    final data = ByteData.sublistView(bytes);
    while (free != 0) {
      final end = free + data.getUint16(free + 2);
      if (ranges.any((range) => range.$1 < end && range.$2 > free)) {
        throw const FormatException('Cell overlaps freeblock');
      }
      free = data.getUint16(free);
    }
  }

  Future<Uint8List> _payload(SqliteByteReader cell, BigInt size,
      {required bool tableLeaf, required Set<int> used}) async {
    if (size > BigInt.from(maxPayloadBytes)) {
      throw const FormatException('Record exceeds configured payload limit');
    }
    final length = size.toInt();
    final usable = pager.header.usableSize;
    final maxLocal = tableLeaf ? usable - 35 : ((usable - 12) * 64 ~/ 255) - 23;
    final minLocal = ((usable - 12) * 32 ~/ 255) - 23;
    var local = length;
    if (length > maxLocal) {
      local = minLocal + (length - minLocal) % (usable - 4);
      if (local > maxLocal) local = minLocal;
    }
    if (local > cell.end - cell.offset ||
        (local < length && cell.end - cell.offset - local < 4) ||
        length > local + (pager.pageCount - 1) * (usable - 4)) {
      throw const FormatException('Invalid local payload or impossible length');
    }
    final result = Uint8List(length);
    result.setRange(0, local, cell.bytes, cell.offset);
    cell.offset += local;
    var copied = local;
    var next = copied == length ? 0 : cell.uint32();
    while (copied < length) {
      if (!used.add(next)) {
        throw const FormatException('Repeated overflow or B-tree page');
      }
      final page = await _readPage(next);
      next = ByteData.sublistView(page).getUint32(0);
      final count = math.min(length - copied, usable - 4);
      result.setRange(copied, copied + count, page, 4);
      copied += count;
    }
    if (next != 0) throw const FormatException('Overlong overflow chain');
    return result;
  }
}
