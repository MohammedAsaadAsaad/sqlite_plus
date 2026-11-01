import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/pointer_map.dart';
import '../format/record_codec.dart';
import '../format/record_encoder.dart';

/// Incremental auto-vacuum freelist pages and `PRAGMA incremental_vacuum`.
///
/// A compact rebuild of an incremental database keeps the original page count
/// and puts the unused pages on the freelist. `apply` then truncates up to the
/// requested number of free pages, moving a live page off the end when the
/// last page is still in use.
abstract final class IncrementalVacuum {
  /// Appends free pages so an incremental image keeps [header]'s page count.
  /// Returns the freelist trunk and page count to store in the header.
  static ({int trunk, int count}) preserve(List<Uint8List> pages,
      Map<int, (int, int)> pointer, DatabaseHeader header) {
    if (header.incrementalVacuum == 0 || header.databaseSize <= pages.length) {
      return (trunk: 0, count: 0);
    }
    final free = <int>[];
    while (pages.length < header.databaseSize) {
      pages.add(Uint8List(header.pageSize));
      final number = pages.length;
      if (PointerMap.isPage(header, number)) continue;
      pointer[number] = (PointerMap.freePage, 0);
      free.add(number);
    }
    if (free.isEmpty) return (trunk: 0, count: 0);
    link(pages, free);
    return (trunk: free.first, count: free.length);
  }

  /// Removes up to [pages] freelist pages. A non-positive count clears the
  /// whole freelist, matching `PRAGMA incremental_vacuum` with no argument,
  /// `0`, or a negative value. The image is returned unchanged when this is
  /// not an incremental database or the freelist is already empty.
  static Uint8List apply(Uint8List image, int pages) {
    final header = DatabaseHeader.decode(image);
    if (header.autoVacuumMode != 2 || header.freelistPages == 0) {
      return image;
    }
    if (!header.hasValidDatabaseSize ||
        header.databaseSize * header.pageSize != image.length ||
        header.reservedBytes != 0) {
      throw const FormatException('Invalid incremental vacuum image');
    }
    var bytes = Uint8List.fromList(image);
    var budget = pages <= 0 ? header.freelistPages : pages;
    var changed = false;
    while (budget > 0) {
      final current = DatabaseHeader.decode(bytes);
      if (current.freelistPages == 0 || current.databaseSize <= 1) break;
      final free = _freePages(bytes, current);
      final last = current.databaseSize;
      if (free.contains(last)) {
        free.remove(last);
        bytes = _finish(bytes, current, free, last - 1);
      } else {
        final dest = free.reduce((a, b) => a < b ? a : b);
        if (dest >= last) break;
        _move(bytes, current, last, dest);
        free.remove(dest);
        bytes = _finish(bytes, current, free, last - 1);
      }
      changed = true;
      budget--;
    }
    if (!changed) return image;
    final fields = ByteData.sublistView(bytes);
    final counter = (header.changeCounter + 1) & 0xffffffff;
    fields.setUint32(24, counter);
    fields.setUint32(92, counter);
    return bytes;
  }

  static void link(List<Uint8List> pages, List<int> freePages) {
    final size = pages.first.length;
    final capacity = size ~/ 4 - 2;
    var cursor = 0;
    while (cursor < freePages.length) {
      final trunk = freePages[cursor];
      cursor++;
      final room = freePages.length - cursor;
      final take = room > capacity ? capacity : room;
      final next =
          cursor + take < freePages.length ? freePages[cursor + take] : 0;
      final page = pages[trunk - 1];
      page.fillRange(0, size, 0);
      final data = ByteData.sublistView(page);
      data.setUint32(0, next);
      data.setUint32(4, take);
      for (var i = 0; i < take; i++) {
        data.setUint32(8 + 4 * i, freePages[cursor + i]);
      }
      cursor += take;
    }
  }

  static List<int> _freePages(Uint8List image, DatabaseHeader header) {
    final pages = <int>[];
    final seen = <int>{};
    var trunk = header.firstFreelistTrunk;
    final data = ByteData.sublistView(image);
    var guard = 0;
    while (trunk != 0) {
      if (trunk < 2 || trunk > header.databaseSize || !seen.add(trunk)) {
        throw const FormatException('Invalid freelist trunk');
      }
      pages.add(trunk);
      final offset = (trunk - 1) * header.pageSize;
      final next = data.getUint32(offset);
      final count = data.getUint32(offset + 4);
      if (count > header.usableSize ~/ 4 - 2) {
        throw const FormatException('Invalid freelist count');
      }
      for (var i = 0; i < count; i++) {
        final leaf = data.getUint32(offset + 8 + 4 * i);
        if (leaf < 2 || leaf > header.databaseSize || !seen.add(leaf)) {
          throw const FormatException('Invalid freelist leaf');
        }
        pages.add(leaf);
      }
      trunk = next;
      if (++guard > header.databaseSize) {
        throw const FormatException('Invalid freelist trunk');
      }
    }
    if (pages.length != header.freelistPages) {
      throw const FormatException('Invalid freelist count');
    }
    return pages;
  }

  static Uint8List _finish(
      Uint8List image, DatabaseHeader header, List<int> free, int pageCount) {
    final size = header.pageSize;
    final next = Uint8List(pageCount * size);
    next.setRange(0, next.length, image);
    final ordered = [...free]..sort();
    if (ordered.isNotEmpty) {
      final views = <Uint8List>[
        for (var page = 0; page < pageCount; page++)
          Uint8List.sublistView(next, page * size, (page + 1) * size)
      ];
      link(views, ordered);
    }
    final removed = pageCount + 1;
    if (removed > 1 && !PointerMap.isPage(header, removed)) {
      final map = PointerMap.mapPage(header, removed);
      if (map <= pageCount) {
        final slot = (map - 1) * size + 5 * (removed - map - 1);
        if (slot >= 0 && slot + 5 <= next.length) {
          next.fillRange(slot, slot + 5, 0);
        }
      }
    }
    final fields = ByteData.sublistView(next);
    fields.setUint32(28, pageCount);
    fields.setUint32(32, ordered.isEmpty ? 0 : ordered.first);
    fields.setUint32(36, ordered.length);
    if (header.largestRootPage > pageCount) {
      fields.setUint32(52, pageCount);
    }
    return next;
  }

  static void _move(Uint8List image, DatabaseHeader header, int from, int to) {
    final size = header.pageSize;
    final entry = _entry(image, header, from);
    final copied = Uint8List.sublistView(image, (from - 1) * size, from * size);
    image.setRange((to - 1) * size, to * size, copied);
    _retarget(image, header, entry, from, to);
    _setEntry(image, header, to, entry.type, entry.parent);
    for (var page = 2; page <= header.databaseSize; page++) {
      if (page == from || page == to || PointerMap.isPage(header, page)) {
        continue;
      }
      final other = _entry(image, header, page);
      if (other.parent == from) {
        _setEntry(image, header, page, other.type, to);
      }
    }
  }

  static void _retarget(Uint8List image, DatabaseHeader header,
      ({int type, int parent}) entry, int from, int to) {
    switch (entry.type) {
      case PointerMap.overflowNext:
        final parent = entry.parent;
        if (parent < 1 || parent > header.databaseSize) {
          throw const FormatException('Invalid overflow parent');
        }
        ByteData.sublistView(image)
            .setUint32((parent - 1) * header.pageSize, to);
      case PointerMap.overflowFirst:
        _patchBtree(image, header, entry.parent, from, to, overflow: true);
      case PointerMap.btree:
        _patchBtree(image, header, entry.parent, from, to, overflow: false);
      case PointerMap.rootPage:
        _patchRoot(image, header, from, to);
      case PointerMap.freePage:
        break;
      default:
        throw const FormatException('Invalid pointer-map type');
    }
  }

  static void _patchBtree(
      Uint8List image, DatabaseHeader header, int page, int from, int to,
      {required bool overflow}) {
    final size = header.pageSize;
    final start = page == 1 ? 100 : 0;
    final offset = (page - 1) * size;
    final bytes = Uint8List.sublistView(image, offset, offset + size);
    final fields = ByteData.sublistView(bytes);
    final type = bytes[start];
    final interior = type == 2 || type == 5;
    final table = type == 5 || type == 13;
    if (!overflow && interior && fields.getUint32(start + 8) == from) {
      fields.setUint32(start + 8, to);
    }
    final count = fields.getUint16(start + 3);
    final pointers = start + (interior ? 12 : 8);
    for (var i = 0; i < count; i++) {
      final cell = fields.getUint16(pointers + 2 * i);
      if (!overflow && interior && fields.getUint32(cell) == from) {
        fields.setUint32(cell, to);
        continue;
      }
      if (!overflow) continue;
      final pointer = _overflowPointer(bytes, cell, type, table, header);
      if (pointer == from) {
        fields.setUint32(cell + _overflowOffset(bytes, cell, type, header), to);
      }
    }
  }

  static int? _overflowPointer(
      Uint8List page, int cell, int type, bool table, DatabaseHeader header) {
    final offset = _overflowOffset(page, cell, type, header);
    if (offset < 0) return null;
    return ByteData.sublistView(page).getUint32(cell + offset);
  }

  static int _overflowOffset(
      Uint8List page, int cell, int type, DatabaseHeader header) {
    final reader = SqliteByteReader(page, offset: cell);
    if (type == 2 || type == 5) reader.uint32();
    final payload = reader.varint().toInt();
    if (type == 5 || type == 13) reader.varint();
    final local =
        _local(header.usableSize, payload, table: type == 5 || type == 13);
    if (payload <= local) return -1;
    return reader.offset - cell + local;
  }

  static int _local(int usable, int payload, {required bool table}) {
    final max = table ? usable - 35 : ((usable - 12) * 64 ~/ 255) - 23;
    final min = ((usable - 12) * 32 ~/ 255) - 23;
    if (payload <= max) return payload;
    var local = min + (payload - min) % (usable - 4);
    if (local > max) local = min;
    return local;
  }

  static void _patchRoot(
      Uint8List image, DatabaseHeader header, int from, int to) {
    final size = header.pageSize;
    final bytes = Uint8List.sublistView(image, 0, size);
    final fields = ByteData.sublistView(bytes);
    final count = fields.getUint16(103);
    for (var i = 0; i < count; i++) {
      final cell = fields.getUint16(108 + 2 * i);
      final reader = SqliteByteReader(bytes, offset: cell);
      final payloadSize = reader.varint().toInt();
      reader.varint();
      final payload = Uint8List.sublistView(
          bytes, reader.offset, reader.offset + payloadSize);
      final values = RecordCodec.decode(payload, encoding: header.textEncoding);
      if (values.length < 4) continue;
      final root = values[3];
      final number = root is BigInt
          ? root.toInt()
          : root is int
              ? root
              : null;
      if (number != from) continue;
      values[3] = BigInt.from(to);
      final encoded =
          RecordEncoder.encode(values, encoding: header.textEncoding);
      if (encoded.length != payload.length) {
        throw const FormatException('Root page move changed a schema record');
      }
      bytes.setRange(reader.offset, reader.offset + encoded.length, encoded);
    }
  }

  static ({int type, int parent}) _entry(
      Uint8List image, DatabaseHeader header, int page) {
    final map = PointerMap.mapPage(header, page);
    final size = header.pageSize;
    final mapBytes = Uint8List.sublistView(image, (map - 1) * size, map * size);
    return PointerMap.entry(mapBytes, header, page);
  }

  static void _setEntry(
      Uint8List image, DatabaseHeader header, int page, int type, int parent) {
    final map = PointerMap.mapPage(header, page);
    final size = header.pageSize;
    final slot = (map - 1) * size + 5 * (page - map - 1);
    image[slot] = type;
    ByteData.sublistView(image).setUint32(slot + 1, parent);
  }
}
