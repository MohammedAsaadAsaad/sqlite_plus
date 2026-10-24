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

  Stream<BtreeRecord> scanTable(int rootPage) => _scan(rootPage, true);
  Stream<BtreeRecord> scanIndex(int rootPage) => _scan(rootPage, false);

  Stream<BtreeRecord> _scan(int root, bool table) async* {
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
        if (child != null) {
          actions.add(
              _PageTask(child, node.table, lower, node.table ? rowId : null));
        }
        if (values != null) actions.add(BtreeRecord._(rowId, values));
        if (node.table) lower = rowId;
      }
      // Cells must not overlap each other or the freeblock chain.
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
      if (!header.isLeaf) {
        actions.add(
            _PageTask(header.rightmostChild!, node.table, lower, node.upper));
      }
      stack.addAll(actions.reversed);
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
