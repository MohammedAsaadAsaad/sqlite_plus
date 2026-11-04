import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

/// Pages and leaf cells of one index B-tree.
class IndexMeasure {
  const IndexMeasure({required this.entries, required this.bytes});

  /// Cells in the index, including keys promoted onto interior pages.
  final int entries;

  /// B-tree pages plus their overflow pages, multiplied by the page size.
  final int bytes;
}

/// Walks the index rooted at [rootPage].
///
/// The engine has no `dbstat` table. The count is every cell in the index,
/// including keys promoted onto interior pages. The size is every page that
/// walk reaches, including overflow pages.
IndexMeasure measureIndex(Uint8List image, int rootPage) {
  final header = DatabaseHeader.decode(image);
  final pageCount = header.validateFileLength(image.length);
  if (rootPage < 1 || rootPage > pageCount) {
    throw FormatException('Index root page $rootPage is outside the file');
  }
  final seen = <int>{};
  var entries = 0;
  var pages = 0;

  void countOverflow(Uint8List page, int cell, int type) {
    var pageNumber = _overflowPage(page, cell, type, header);
    while (pageNumber != null &&
        pageNumber > 0 &&
        pageNumber <= pageCount &&
        seen.add(pageNumber)) {
      pages++;
      final next =
          ByteData.sublistView(_slice(image, header, pageNumber)).getUint32(0);
      pageNumber = next == 0 ? null : next;
    }
  }

  void walk(int pageNumber) {
    if (pageNumber < 1 || pageNumber > pageCount || !seen.add(pageNumber)) {
      return;
    }
    final page = _slice(image, header, pageNumber);
    final BtreePageHeader decoded;
    try {
      decoded = BtreePageHeader.decode(
        page,
        database: header,
        pageNumber: pageNumber,
      );
    } on FormatException {
      return;
    }
    pages++;
    // A promoted index key lives on the interior page, so every cell counts.
    entries += decoded.cellCount;
    if (!decoded.isLeaf) {
      final data = ByteData.sublistView(page);
      for (final cell in decoded.cellOffsets) {
        if (cell + 4 <= page.length) walk(data.getUint32(cell));
      }
      final right = decoded.rightmostChild;
      if (right != null) walk(right);
    }
    for (final cell in decoded.cellOffsets) {
      countOverflow(page, cell, decoded.type);
    }
  }

  walk(rootPage);
  return IndexMeasure(entries: entries, bytes: pages * header.pageSize);
}

Uint8List _slice(Uint8List image, DatabaseHeader header, int pageNumber) {
  final size = header.pageSize;
  final start = (pageNumber - 1) * size;
  return Uint8List.sublistView(image, start, start + size);
}

/// First overflow page of a cell, or null when the payload fits locally.
///
/// The split matches the SQLite file format: index pages use the smaller
/// local-payload limit, and table pages use `usable - 35`.
int? _overflowPage(
  Uint8List page,
  int cell,
  int type,
  DatabaseHeader header,
) {
  if (cell < 0 || cell >= page.length) return null;
  final reader = SqliteByteReader(page, offset: cell);
  final interior = type == 2 || type == 5;
  final table = type == 5 || type == 13;
  try {
    if (interior) reader.uint32();
    final payload = reader.varint().toInt();
    if (payload < 0) return null;
    if (table) reader.varint();
    final local = _localPayload(header.usableSize, payload, table: table);
    if (payload <= local) return null;
    final at = reader.offset + local;
    if (at < 0 || at + 4 > page.length) return null;
    final next = ByteData.sublistView(page).getUint32(at);
    return next == 0 ? null : next;
  } on FormatException {
    return null;
  }
}

int _localPayload(int usable, int payload, {required bool table}) {
  final max = table ? usable - 35 : ((usable - 12) * 64 ~/ 255) - 23;
  final min = ((usable - 12) * 32 ~/ 255) - 23;
  if (payload <= max) return payload;
  var local = min + (payload - min) % (usable - 4);
  if (local > max) local = min;
  return local;
}
