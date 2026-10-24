import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/record_encoder.dart';
import '../sql/tokenizer.dart';
import 'table_image_writer.dart';

final class ImageObject {
  ImageObject(this.type, this.name, this.tableName, this.sql,
      {this.tableRows = const [],
      this.indexRows = const [],
      this.indexTable = false});
  final String type, name, tableName;
  final String? sql;
  final bool indexTable;
  final List<TableRow> tableRows;
  final List<List<Object?>> indexRows;
  int rootPage = 0;
}

/// Compact reconstruction of SQLite rowid and index B-trees. The caller supplies
/// validated/sorted logical records and commits the returned image atomically.
abstract final class DatabaseImageBuilder {
  static Uint8List empty({int pageSize = 4096, int encoding = 1}) {
    if (pageSize < 512 ||
        pageSize > 65536 ||
        pageSize & (pageSize - 1) != 0 ||
        encoding < 1 ||
        encoding > 3) {
      throw ArgumentError('Invalid database format');
    }
    final image = Uint8List(pageSize);
    image.setRange(0, 16, [
      83,
      81,
      76,
      105,
      116,
      101,
      32,
      102,
      111,
      114,
      109,
      97,
      116,
      32,
      51,
      0
    ]);
    final data = ByteData.sublistView(image);
    data.setUint16(16, pageSize == 65536 ? 1 : pageSize);
    image[18] = 1;
    image[19] = 1;
    image[21] = 64;
    image[22] = 32;
    image[23] = 32;
    data.setUint32(24, 1);
    data.setUint32(28, 1);
    data.setUint32(44, 4);
    data.setUint32(56, encoding);
    data.setUint32(92, 1);
    data.setUint32(96, 3053001);
    image[100] = 13;
    data.setUint16(105, pageSize == 65536 ? 0 : pageSize);
    return image;
  }

  static Uint8List build(Uint8List original, List<ImageObject> objects,
      {bool schemaChanged = false, int maxImageBytes = 64 * 1024 * 1024}) {
    final header = DatabaseHeader.decode(original);
    final size = header.pageSize;
    if (header.largestRootPage != 0 || header.reservedBytes != 0) {
      throw UnsupportedError(
          'Auto-vacuum/reserved-byte image rebuild is unsupported');
    }
    final roots = objects
        .where((object) => object.type == 'table' || object.type == 'index')
        .toList();
    final pages = <Uint8List>[
      Uint8List(size),
      for (final _ in roots) Uint8List(size)
    ];
    pages[0].setRange(0, 100, original);
    for (var i = 0; i < roots.length; i++) {
      roots[i].rootPage = i + 2;
    }
    int allocate() {
      if ((pages.length + 1) * size > maxImageBytes) {
        throw const SqlException('Database image limit exceeded');
      }
      pages.add(Uint8List(size));
      return pages.length;
    }

    Uint8List payloadCell(List<Object?> values, bool table, {BigInt? rowid}) {
      final payload =
          RecordEncoder.encode(values, encoding: header.textEncoding);
      final max = table ? size - 35 : ((size - 12) * 64 ~/ 255) - 23;
      final min = ((size - 12) * 32 ~/ 255) - 23;
      var local = payload.length;
      if (local > max) {
        local = min + (payload.length - min) % (size - 4);
        if (local > max) local = min;
      }
      var first = 0;
      var last = 0;
      for (var offset = local; offset < payload.length; offset += size - 4) {
        final n = allocate();
        if (first == 0) first = n;
        if (last != 0) ByteData.sublistView(pages[last - 1]).setUint32(0, n);
        final length = payload.length - offset < size - 4
            ? payload.length - offset
            : size - 4;
        pages[n - 1].setRange(4, 4 + length, payload, offset);
        last = n;
      }
      final prefix = [
        ...RecordEncoder.varint(BigInt.from(payload.length)),
        if (table) ...RecordEncoder.varint(rowid!.toUnsigned(64))
      ];
      final result = Uint8List(prefix.length + local + (first == 0 ? 0 : 4));
      result.setRange(0, prefix.length, prefix);
      result.setRange(prefix.length, prefix.length + local, payload);
      if (first != 0) {
        ByteData.sublistView(result).setUint32(result.length - 4, first);
      }
      return result;
    }

    void write(int number, List<Uint8List> cells, int type, {int? right}) {
      final start = number == 1 ? 100 : 0;
      final length = type == 2 || type == 5 ? 12 : 8;
      final page = pages[number - 1];
      page.fillRange(start, size, 0);
      final data = ByteData.sublistView(page);
      page[start] = type;
      data.setUint16(start + 3, cells.length);
      if (right != null) data.setUint32(start + 8, right);
      var end = size;
      for (var i = 0; i < cells.length; i++) {
        end -= cells[i].length;
        if (end < start + length + 2 * cells.length) {
          throw StateError('B-tree node overflow');
        }
        page.setRange(end, end + cells[i].length, cells[i]);
        data.setUint16(start + length + 2 * i, end);
      }
      data.setUint16(start + 5, end == 65536 ? 0 : end);
    }

    Uint8List tableSeparator(int child, BigInt key) {
      final bytes =
          Uint8List(4 + RecordEncoder.varint(key.toUnsigned(64)).length);
      ByteData.sublistView(bytes).setUint32(0, child);
      bytes.setRange(4, bytes.length, RecordEncoder.varint(key.toUnsigned(64)));
      return bytes;
    }

    void tableTree(int root, List<TableRow> records) {
      final sorted = records.toList()
        ..sort((a, b) => a.rowId.compareTo(b.rowId));
      for (var i = 0; i < sorted.length; i++) {
        if (sorted[i].rowId < -(BigInt.one << 63) ||
            sorted[i].rowId >= BigInt.one << 63 ||
            i > 0 && sorted[i].rowId == sorted[i - 1].rowId) {
          throw const SqlException('Duplicate or invalid rowid');
        }
      }
      final cells = [
        for (final row in sorted)
          payloadCell(row.values, true, rowid: row.rowId)
      ];
      if (cells.fold<int>(root == 1 ? 108 : 8, (s, c) => s + c.length + 2) <=
          size) {
        write(root, cells, 13);
        return;
      }
      var nodes = <(int, BigInt)>[];
      var begin = 0;
      while (begin < cells.length) {
        var end = begin;
        var used = 8;
        while (end < cells.length && used + cells[end].length + 2 <= size) {
          used += cells[end++].length + 2;
        }
        if (end == begin) throw StateError('Table cell cannot fit');
        final n = allocate();
        write(n, cells.sublist(begin, end), 13);
        nodes.add((n, sorted[end - 1].rowId));
        begin = end;
      }
      while (true) {
        final cells = [
          for (final node in nodes.take(nodes.length - 1))
            tableSeparator(node.$1, node.$2)
        ];
        if (cells.fold<int>(root == 1 ? 112 : 12, (s, c) => s + c.length + 2) <=
            size) {
          write(root, cells, 5, right: nodes.last.$1);
          return;
        }
        final next = <(int, BigInt)>[];
        var begin = 0;
        while (begin < nodes.length) {
          var end = begin + 1;
          var used = 12;
          while (end < nodes.length) {
            final cost =
                tableSeparator(nodes[end - 1].$1, nodes[end - 1].$2).length + 2;
            if (used + cost > size) break;
            used += cost;
            end++;
          }
          // A non-root interior page needs a key and at least two children.
          // Redistribute the tail before allocating a singleton child group.
          if (end == nodes.length - 1 && end - begin > 2) end--;
          final n = allocate();
          write(
              n,
              [
                for (final node in nodes.sublist(begin, end - 1))
                  tableSeparator(node.$1, node.$2)
              ],
              5,
              right: nodes[end - 1].$1);
          next.add((n, nodes[end - 1].$2));
          begin = end;
        }
        nodes = next;
      }
    }

    void indexTree(int root, List<List<Object?>> records) {
      // A promoted index cell retains its payload/overflow chain; only its
      // four-byte child prefix changes between leaf and interior nodes.
      final cells = [for (final row in records) payloadCell(row, false)];
      if (cells.fold<int>(8, (s, c) => s + c.length + 2) <= size) {
        write(root, cells, 10);
        return;
      }
      Uint8List interior(int child, Uint8List key) {
        final bytes = Uint8List(key.length + 4);
        ByteData.sublistView(bytes).setUint32(0, child);
        bytes.setRange(4, bytes.length, key);
        return bytes;
      }

      var children = <int>[];
      var keys = <Uint8List>[];
      var begin = 0;
      while (begin < cells.length) {
        var end = begin;
        var used = 8;
        while (end < cells.length && used + cells[end].length + 2 <= size) {
          used += cells[end++].length + 2;
        }
        if (end == begin) throw StateError('Index cell cannot fit');
        if (end < cells.length && end == cells.length - 1) end--;
        final n = allocate();
        write(n, cells.sublist(begin, end), 10);
        children.add(n);
        if (end < cells.length) {
          keys.add(cells[end]);
          begin = end + 1;
        } else {
          begin = end;
        }
      }
      while (true) {
        if (keys.fold<int>(12, (s, c) => s + c.length + 6) <= size) {
          write(
              root,
              [
                for (var i = 0; i < keys.length; i++)
                  interior(children[i], keys[i])
              ],
              2,
              right: children.last);
          return;
        }
        final nextChildren = <int>[];
        final nextKeys = <Uint8List>[];
        var begin = 0;
        while (begin < children.length) {
          var end = begin + 1;
          var used = 12;
          while (end < children.length &&
              used + keys[end - 1].length + 6 <= size) {
            used += keys[end - 1].length + 6;
            end++;
          }
          if (end < children.length && end == children.length - 1) end--;
          final n = allocate();
          write(
              n,
              [
                for (var i = begin; i < end - 1; i++)
                  interior(children[i], keys[i])
              ],
              2,
              right: children[end - 1]);
          nextChildren.add(n);
          if (end < children.length) {
            nextKeys.add(keys[end - 1]);
            begin = end;
          } else {
            begin = end;
          }
        }
        children = nextChildren;
        keys = nextKeys;
      }
    }

    for (final object in roots) {
      if (object.type == 'table' && !object.indexTable) {
        tableTree(object.rootPage, object.tableRows);
      } else {
        indexTree(object.rootPage, object.indexRows);
      }
    }
    tableTree(1, [
      for (var i = 0; i < objects.length; i++)
        TableRow(BigInt.from(i + 1), [
          objects[i].type,
          objects[i].name,
          objects[i].tableName,
          BigInt.from(objects[i].rootPage),
          objects[i].sql
        ])
    ]);
    final data = ByteData.sublistView(pages.first);
    final counter = (header.changeCounter + 1) % 0x100000000;
    data.setUint32(24, counter);
    data.setUint32(92, counter);
    data.setUint32(28, pages.length);
    data.setUint32(32, 0);
    data.setUint32(36, 0);
    if (schemaChanged) {
      data.setUint32(40, (header.schemaCookie + 1) % 0x100000000);
    }
    data.setUint32(44, 4);
    data.setUint32(96, 3053001);
    return Uint8List.fromList(pages.expand((p) => p).toList());
  }
}
