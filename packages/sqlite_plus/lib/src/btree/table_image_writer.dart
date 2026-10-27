import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/record_encoder.dart';
import '../sql/catalog.dart';
import '../sql/tokenizer.dart';
import '../storage/memory_storage_backend.dart';
import '../pager/read_only_pager.dart';
import 'btree_reader.dart';

final class TableRow {
  TableRow(this.rowId, List<Object?> values)
      : values = List.unmodifiable(values);
  final BigInt rowId;

  /// Physical values, with NULL in INTEGER PRIMARY KEY alias fields.
  final List<Object?> values;
}

final class _Node {
  _Node(this.page, this.maximum);
  final int page;
  final BigInt maximum;
}

/// Copy-on-write bulk reconstruction of a simple rowid table in a SQLite image.
/// Indexed/triggered, WITHOUT ROWID and auto-vacuum targets fail explicitly.
/// Existing descendant pages become freelist pages; root/schema stay stable.
abstract final class TableImageWriter {
  static Future<Uint8List> replace(
      Uint8List image, String tableName, List<TableRow> rows,
      {int maxImageBytes = 64 * 1024 * 1024,
      bool preserveIndexes = false}) async {
    if (image.length > maxImageBytes) {
      throw const FormatException('Image limit exceeded');
    }
    final original = Uint8List.fromList(image);
    final header = DatabaseHeader.decode(original);
    final storage = MemoryStorageBackend();
    await storage.write(0, original);
    final pager = await ReadOnlyPager.open(storage);
    try {
      if (!header.hasValidDatabaseSize ||
          header.databaseSize * header.pageSize != image.length ||
          header.largestRootPage != 0 ||
          header.reservedBytes != 0) {
        throw UnsupportedError(
            'Writer requires complete non-auto-vacuum image without reserved bytes');
      }
      final catalog = await DatabaseCatalog.read(pager);
      final table = catalog.table(tableName);
      final definition = catalog.entries
          .where((entry) => entry.name.toLowerCase() == tableName.toLowerCase())
          .firstOrNull;
      if (definition == null ||
          definition.sql == null ||
          RegExp(r'\b(NOT|UNIQUE|CHECK|REFERENCES|DEFAULT|COLLATE|AUTOINCREMENT|GENERATED|CONSTRAINT)\b',
                  caseSensitive: false)
              .hasMatch(definition.sql!)) {
        throw UnsupportedError('Unsupported writable table constraints');
      }

      if (table.rootPage == 1 ||
          table.withoutRowid ||
          (!preserveIndexes &&
              catalog.entries.any((e) =>
                  e.tableName.toLowerCase() == tableName.toLowerCase() &&
                  e.type != 'table'))) {
        throw UnsupportedError(
            'Only ordinary rowid tables without indexes/triggers are writable');
      }
      // Refuse cross-tree aliases and corrupt freelists before reclaiming pages.
      final owned = <int>{};
      final oldPages = <int>{};
      final roots = [
        1,
        ...catalog.entries.where((e) => e.rootPage != 0).map((e) => e.rootPage)
      ];
      for (final root in roots) {
        final first = await pager.readPage(root);
        final offset = root == 1 ? 100 : 0;
        final reader = BtreeReader(pager, onPageRead: (number) {
          if (!owned.add(number)) {
            throw const FormatException('Cross-tree page alias');
          }
          if (root == table.rootPage) oldPages.add(number);
        });
        final scan = [5, 13].contains(first[offset])
            ? reader.scanTable(root)
            : reader.scanIndex(root);
        await scan.drain<void>();
      }
      var freePage = header.firstFreelistTrunk;
      var freeCount = 0;
      final pooled = <int>[];
      while (freePage != 0) {
        if (freePage == 1 || !owned.add(freePage)) {
          throw const FormatException('Invalid freelist trunk');
        }
        final page = await pager.readPage(freePage);
        final data = ByteData.sublistView(page);
        final count = data.getUint32(4);
        if (count > header.usableSize ~/ 4 - 2) {
          throw const FormatException('Invalid freelist count');
        }
        freeCount++;
        pooled.add(freePage);
        for (var i = 0; i < count; i++) {
          final number = data.getUint32(8 + 4 * i);
          if (number < 2 || number > pager.pageCount || !owned.add(number)) {
            throw const FormatException('Invalid freelist leaf');
          }
          freeCount++;
          pooled.add(number);
        }
        freePage = data.getUint32(0);
      }
      if (freeCount != header.freelistPages ||
          owned.length != pager.pageCount) {
        throw const FormatException(
            'Freelist count mismatch or unowned database pages');
      }
      oldPages.remove(table.rootPage);
      final reusable = [...oldPages, ...pooled];
      final sorted = rows.toList()..sort((a, b) => a.rowId.compareTo(b.rowId));
      BigInt? previous;
      for (final row in sorted) {
        if (row.rowId < -(BigInt.one << 63) ||
            row.rowId >= BigInt.one << 63 ||
            previous == row.rowId ||
            row.values.length != table.columns.length) {
          throw const SqlException(
              'Invalid rowid, duplicate key or record width');
        }
        if (table.rowidAlias != null &&
            row.values[table.columns
                    .indexWhere((c) => c.name == table.rowidAlias)] !=
                null) {
          throw const SqlException(
              'Rowid alias must be NULL in physical values');
        }
        previous = row.rowId;
      }
      final pages = <Uint8List>[
        for (var i = 0; i < original.length; i += header.pageSize)
          Uint8List.fromList(original.sublist(i, i + header.pageSize))
      ];
      int allocate() {
        if (reusable.isNotEmpty) return reusable.removeLast();
        if ((pages.length + 1) * header.pageSize > maxImageBytes) {
          throw const FormatException('Image limit exceeded');
        }
        pages.add(Uint8List(header.pageSize));
        return pages.length;
      }

      final size = header.pageSize;
      final cells = <Uint8List>[];
      for (final row in sorted) {
        final payload =
            RecordEncoder.encode(row.values, encoding: header.textEncoding);
        var local = payload.length;
        final minLocal = ((size - 12) * 32 ~/ 255) - 23;
        if (local > size - 35) {
          local = minLocal + (payload.length - minLocal) % (size - 4);
          if (local > size - 35) local = minLocal;
        }
        var first = 0;
        var last = 0;
        for (var offset = local; offset < payload.length; offset += size - 4) {
          final number = allocate();
          if (first == 0) first = number;
          if (last != 0) {
            ByteData.sublistView(pages[last - 1]).setUint32(0, number);
          }
          final count = payload.length - offset < size - 4
              ? payload.length - offset
              : size - 4;
          final overflow = Uint8List(size);
          overflow.setRange(4, 4 + count, payload, offset);
          pages[number - 1] = overflow;
          last = number;
        }
        final prefix = [
          ...RecordEncoder.varint(BigInt.from(payload.length)),
          ...RecordEncoder.varint(row.rowId.toUnsigned(64))
        ];
        final cell = Uint8List(prefix.length + local + (first == 0 ? 0 : 4));
        cell.setRange(0, prefix.length, prefix);
        cell.setRange(prefix.length, prefix.length + local, payload);
        if (first != 0) {
          ByteData.sublistView(cell).setUint32(cell.length - 4, first);
        }
        cells.add(cell);
      }
      void writePage(int number, List<Uint8List> contents, {int? right}) {
        final page = Uint8List(size);
        final data = ByteData.sublistView(page);
        page[0] = right == null ? 13 : 5;
        data.setUint16(3, contents.length);
        var end = size;
        final start = right == null ? 8 : 12;
        if (right != null) data.setUint32(8, right);
        for (var i = 0; i < contents.length; i++) {
          end -= contents[i].length;
          if (end < start + 2 * contents.length) {
            throw StateError('Page overflow');
          }
          page.setRange(end, end + contents[i].length, contents[i]);
          data.setUint16(start + i * 2, end);
        }
        data.setUint16(5, end == 65536 ? 0 : end);
        pages[number - 1] = page;
      }

      if (cells.fold<int>(8, (sum, c) => sum + c.length + 2) <= size) {
        writePage(table.rootPage, cells);
      } else {
        var nodes = <_Node>[];
        var start = 0;
        while (start < cells.length) {
          var end = start;
          var used = 8;
          while (end < cells.length && used + cells[end].length + 2 <= size) {
            used += cells[end++].length + 2;
          }
          if (end == start) throw StateError('Cell cannot fit page');
          final number = allocate();
          writePage(number, cells.sublist(start, end));
          nodes.add(_Node(number, sorted[end - 1].rowId));
          start = end;
        }
        List<Uint8List> interior(List<_Node> children) => [
              for (final child in children.take(children.length - 1))
                Uint8List.fromList([
                  ...(Uint8List(4)
                    ..buffer.asByteData().setUint32(0, child.page)),
                  ...RecordEncoder.varint(child.maximum.toUnsigned(64))
                ])
            ];
        while (true) {
          final rootCells = interior(nodes);
          if (rootCells.fold<int>(12, (sum, c) => sum + c.length + 2) <= size) {
            writePage(table.rootPage, rootCells, right: nodes.last.page);
            break;
          }
          final next = <_Node>[];
          var begin = 0;
          while (begin < nodes.length) {
            var end = begin + 1;
            var used = 12;
            while (end < nodes.length) {
              final cost = 6 +
                  RecordEncoder.varint(nodes[end - 1].maximum.toUnsigned(64))
                      .length;
              if (used + cost > size) break;
              used += cost;
              end++;
            }
            final children = nodes.sublist(begin, end);
            final number = allocate();
            writePage(number, interior(children), right: children.last.page);
            next.add(_Node(number, children.last.maximum));
            begin = end;
          }
          nodes = next;
        }
      }
      // Reclaim unused former tree and freelist pages as one new freelist.
      var trunk = 0;
      final free = reusable;
      final freed = free.length;
      while (free.isNotEmpty) {
        final number = free.removeLast();
        final page = Uint8List(size);
        final data = ByteData.sublistView(page);
        data.setUint32(0, trunk);
        final count = free.length < size ~/ 4 - 2 ? free.length : size ~/ 4 - 2;
        data.setUint32(4, count);
        for (var i = 0; i < count; i++) {
          data.setUint32(8 + i * 4, free.removeLast());
        }
        pages[number - 1] = page;
        trunk = number;
      }
      final fields = ByteData.sublistView(pages.first);
      final counter = (header.changeCounter + 1) % 0x100000000;
      fields.setUint32(24, counter);
      fields.setUint32(92, counter);
      fields.setUint32(28, pages.length);
      fields.setUint32(32, trunk);
      fields.setUint32(36, freed);
      return Uint8List.fromList(pages.expand((p) => p).toList());
    } finally {
      await pager.close();
    }
  }
}
