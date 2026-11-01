import 'dart:typed_data';

import 'database_header.dart';

/// Auto-vacuum pointer-map pages. Page 1 has no entry. A map page is not a
/// B-tree page. Non-vacuum images (`largestRootPage == 0`) never consult this.
abstract final class PointerMap {
  static const rootPage = 1;
  static const freePage = 2;
  static const overflowFirst = 3;
  static const overflowNext = 4;
  static const btree = 5;
  static const pendingByte = 0x40000000;

  static int pendingPage(int pageSize) => (pendingByte ~/ pageSize) + 1;

  static int mapPage(DatabaseHeader header, int page) {
    if (page < 2) return 0;
    final pending = pendingPage(header.pageSize);
    final perMap = (header.usableSize ~/ 5) + 1;
    final index = (page - 2) ~/ perMap;
    var map = index * perMap + 2;
    if (map == pending) map++;
    return map;
  }

  static bool isPage(DatabaseHeader header, int page) {
    if (header.largestRootPage == 0 || page < 2) return false;
    if (page == pendingPage(header.pageSize)) return false;
    return mapPage(header, page) == page;
  }

  /// Type and parent page for [page]. The map page itself has no entry.
  static ({int type, int parent}) entry(
      Uint8List mapBytes, DatabaseHeader header, int page) {
    if (header.largestRootPage == 0) {
      throw const FormatException('Database has no pointer map');
    }
    if (page < 2 || isPage(header, page)) {
      throw const FormatException('Page has no pointer-map entry');
    }
    final map = mapPage(header, page);
    final offset = 5 * (page - map - 1);
    if (offset < 0 || offset + 5 > header.usableSize) {
      throw const FormatException('Pointer-map entry is outside the page');
    }
    if (mapBytes.length != header.pageSize) {
      throw const FormatException('Incorrect page length');
    }
    final type = mapBytes[offset];
    if (type < rootPage || type > btree) {
      throw const FormatException('Invalid pointer-map type');
    }
    final parent = ByteData.sublistView(mapBytes).getUint32(offset + 1);
    return (type: type, parent: parent);
  }
}
