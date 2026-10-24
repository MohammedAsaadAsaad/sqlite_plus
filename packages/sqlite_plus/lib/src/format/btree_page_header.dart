import 'dart:typed_data';

import 'database_header.dart';

/// Structural B-tree page framing only; cells and records are not decoded.
final class BtreePageHeader {
  BtreePageHeader._(
      this.type,
      this.firstFreeblock,
      this.cellCount,
      this.cellContentOffset,
      this.fragmentedBytes,
      this.rightmostChild,
      this.cellOffsets);

  final int type;
  final int firstFreeblock;
  final int cellCount;
  final int cellContentOffset;
  final int fragmentedBytes;
  final int? rightmostChild;
  final List<int> cellOffsets;
  bool get isLeaf => type == 10 || type == 13;
  bool get isTable => type == 5 || type == 13;

  factory BtreePageHeader.decode(Uint8List page,
      {required DatabaseHeader database, required int pageNumber}) {
    if (pageNumber < 1) throw RangeError.value(pageNumber, 'pageNumber');
    if (page.length != database.pageSize) {
      throw const FormatException('Incorrect page length');
    }
    final start = pageNumber == 1 ? 100 : 0;
    final data = ByteData.sublistView(page);
    final type = page[start];
    if (![2, 5, 10, 13].contains(type)) {
      throw const FormatException('Invalid B-tree page type');
    }
    final leaf = type == 10 || type == 13;
    final headerEnd = start + (leaf ? 8 : 12);
    final freeblock = data.getUint16(start + 1);
    final count = data.getUint16(start + 3);
    if (!leaf && count == 0 && pageNumber != 1) {
      throw const FormatException('Empty interior page outside page one');
    }
    final rawContent = data.getUint16(start + 5);
    final content = rawContent == 0 ? 65536 : rawContent;
    final fragments = page[start + 7];
    final pointerEnd = headerEnd + 2 * count;
    final usable = database.usableSize;
    if (pointerEnd > content || content > usable || fragments > 60) {
      throw const FormatException('Invalid cell area or fragments');
    }
    final child = leaf ? null : data.getUint32(start + 8);
    if (child == 0) throw const FormatException('Zero rightmost child');
    final offsets = <int>[];
    final seen = <int>{};
    for (var i = 0; i < count; i++) {
      final offset = data.getUint16(headerEnd + i * 2);
      if (offset < content || offset >= usable || !seen.add(offset)) {
        throw const FormatException('Invalid or duplicate cell pointer');
      }
      offsets.add(offset);
    }
    var block = freeblock;
    while (block != 0) {
      if (block < content || block + 4 > usable) {
        throw const FormatException('Invalid freeblock offset');
      }
      final next = data.getUint16(block);
      final size = data.getUint16(block + 2);
      if (size < 4 ||
          block + size > usable ||
          (next != 0 && next < block + size + 4)) {
        throw const FormatException('Invalid freeblock chain');
      }
      if (offsets.any((offset) => offset >= block && offset < block + size)) {
        throw const FormatException('Cell points into freeblock');
      }
      block = next;
    }
    return BtreePageHeader._(type, freeblock, count, content, fragments, child,
        List.unmodifiable(offsets));
  }
}
