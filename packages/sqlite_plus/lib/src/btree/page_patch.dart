import 'dart:math';
import 'dart:typed_data';

import '../format/btree_page_header.dart';
import '../format/database_header.dart';
import '../format/record_codec.dart';
import '../format/record_encoder.dart';
import '../pager/read_only_pager.dart';
import '../sql/catalog.dart';
import '../storage/memory_storage_backend.dart';

/// In-place overflow update for one rowid-table row.
///
/// Returns null unless the new record has the same payload length and the
/// first changed byte is past the cell-local prefix. Page 1's change counter
/// is bumped. Every other unmodified page stays byte-for-byte identical.
Future<Uint8List?> patchTableOverflow(
    Uint8List image, String table, BigInt rowid, List<Object?> values) async {
  if (image.length < 100) return null;
  final header = DatabaseHeader.decode(image);
  if (header.largestRootPage != 0 ||
      header.reservedBytes != 0 ||
      header.writeVersion != 1 ||
      !header.hasValidDatabaseSize ||
      header.databaseSize * header.pageSize != image.length) {
    return null;
  }
  final storage = MemoryStorageBackend();
  await storage.write(0, image);
  final pager = await ReadOnlyPager.open(storage);
  try {
    final catalog = await DatabaseCatalog.read(pager);
    final definition = catalog.table(table);
    if (definition.withoutRowid || definition.rootPage <= 1) return null;
    final encoded = RecordEncoder.encode(values, encoding: header.textEncoding);
    final location = _findLeaf(image, header, definition.rootPage, rowid);
    if (location == null) return null;
    final stored = _readPayload(image, header.pageSize, location);
    if (stored == null || stored.length != encoded.length) return null;
    var difference = -1;
    for (var i = 0; i < encoded.length; i++) {
      if (stored[i] != encoded[i]) {
        difference = i;
        break;
      }
    }
    if (difference < 0 || difference < location.local) return null;
    final copy = Uint8List.fromList(image);
    var offset = location.local;
    var page = location.overflow;
    while (offset < encoded.length) {
      if (page < 2 || page > header.databaseSize) return null;
      final count = min(header.pageSize - 4, encoded.length - offset);
      final start = (page - 1) * header.pageSize;
      final link = ByteData.sublistView(copy).getUint32(start);
      if (difference < offset + count) {
        final skip = max(0, difference - offset);
        copy.setRange(
            start + 4 + skip, start + 4 + count, encoded, offset + skip);
      }
      offset += count;
      page = link;
      if (offset < encoded.length && page == 0) return null;
    }
    final counter = (header.changeCounter + 1) & 0xffffffff;
    final fields = ByteData.sublistView(copy);
    fields.setUint32(24, counter);
    fields.setUint32(92, counter);
    return copy;
  } on FormatException {
    return null;
  } finally {
    await pager.close();
  }
}

final class _LeafCell {
  _LeafCell(this.local, this.overflow, this.pageOffset, this.cellOffset);
  final int local;
  final int overflow;
  final int pageOffset;
  final int cellOffset;
}

_LeafCell? _findLeaf(
    Uint8List image, DatabaseHeader header, int root, BigInt rowid) {
  final size = header.pageSize;
  var number = root;
  final seen = <int>{};
  while (seen.add(number)) {
    if (number < 1 || number > header.databaseSize) return null;
    final page =
        Uint8List.sublistView(image, (number - 1) * size, number * size);
    final decoded =
        BtreePageHeader.decode(page, database: header, pageNumber: number);
    if (!decoded.isTable) return null;
    if (decoded.isLeaf) {
      for (final cellOffset in decoded.cellOffsets) {
        final cell = SqliteByteReader(page, offset: cellOffset, end: size);
        final payload = cell.varint();
        final key = cell.varint().toSigned(64);
        if (key != rowid) continue;
        if (payload > BigInt.from(image.length)) return null;
        final length = payload.toInt();
        final local = _local(length, size);
        final overflow = length > local
            ? ByteData.sublistView(page).getUint32(cell.offset + local)
            : 0;
        return _LeafCell(local, overflow, (number - 1) * size, cellOffset);
      }
      return null;
    }
    var child = decoded.rightmostChild;
    for (final cellOffset in decoded.cellOffsets) {
      final cell = SqliteByteReader(page, offset: cellOffset, end: size);
      final left = cell.uint32();
      final key = cell.varint().toSigned(64);
      if (rowid <= key) {
        child = left;
        break;
      }
    }
    if (child == null) return null;
    number = child;
  }
  return null;
}

int _local(int payload, int pageSize) {
  final maximum = pageSize - 35;
  if (payload <= maximum) return payload;
  final minimum = ((pageSize - 12) * 32 ~/ 255) - 23;
  var local = minimum + (payload - minimum) % (pageSize - 4);
  if (local > maximum) local = minimum;
  return local;
}

Uint8List? _readPayload(Uint8List image, int pageSize, _LeafCell cell) {
  final page =
      Uint8List.sublistView(image, cell.pageOffset, cell.pageOffset + pageSize);
  final reader = SqliteByteReader(page, offset: cell.cellOffset, end: pageSize);
  final length = reader.varint().toInt();
  reader.varint();
  if (reader.offset + cell.local > pageSize) return null;
  final payload = Uint8List(length);
  payload.setRange(0, cell.local, page, reader.offset);
  var filled = cell.local;
  var next = cell.overflow;
  final seen = <int>{};
  while (filled < length) {
    if (next < 2 || !seen.add(next)) return null;
    final start = (next - 1) * pageSize;
    if (start + pageSize > image.length) return null;
    final count = min(pageSize - 4, length - filled);
    payload.setRange(filled, filled + count, image, start + 4);
    filled += count;
    next = ByteData.sublistView(image).getUint32(start);
  }
  return payload;
}
