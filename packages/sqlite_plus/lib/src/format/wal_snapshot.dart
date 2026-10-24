import 'dart:typed_data';

import 'database_header.dart';

/// Read-only WAL recovery for a stable main-file + WAL copy. No shared-memory
/// wal-index, live writer coordination, WAL generation, checkpoint locks or I/O.
abstract final class WalSnapshot {
  static Uint8List recover(Uint8List database, Uint8List wal,
      {int maxImageBytes = 64 * 1024 * 1024}) {
    final header = DatabaseHeader.decode(database);
    if (database.length > maxImageBytes) {
      throw const FormatException('Image limit exceeded');
    }
    header.validateFileLength(database.length);
    if (wal.isEmpty) return Uint8List.fromList(database);
    if (wal.length < 32) throw const FormatException('Truncated WAL header');
    final data = ByteData.sublistView(wal);
    final magic = data.getUint32(0);
    if (![0x377f0682, 0x377f0683].contains(magic) ||
        data.getUint32(4) != 3007000 ||
        data.getUint32(8) != header.pageSize) {
      throw const FormatException('Invalid WAL header');
    }
    final endian = magic == 0x377f0682 ? Endian.little : Endian.big;
    var sum = _checksum(Uint8List.sublistView(wal, 0, 24), 0, 0, endian);
    if (sum.$1 != data.getUint32(24) || sum.$2 != data.getUint32(28)) {
      throw const FormatException('Invalid WAL header checksum');
    }
    final salt1 = data.getUint32(16);
    final salt2 = data.getUint32(20);
    final pending = <int, Uint8List>{};
    var committed = <int, Uint8List>{};
    var pageCount = database.length ~/ header.pageSize;
    final stride = 24 + header.pageSize;
    for (var offset = 32; offset + stride <= wal.length; offset += stride) {
      final number = data.getUint32(offset);
      final size = data.getUint32(offset + 4);
      if (number == 0 ||
          data.getUint32(offset + 8) != salt1 ||
          data.getUint32(offset + 12) != salt2) {
        break;
      }
      final frame = Uint8List.sublistView(wal, offset + 24, offset + stride);
      final first = _checksum(Uint8List.sublistView(wal, offset, offset + 8),
          sum.$1, sum.$2, endian);
      final next = _checksum(frame, first.$1, first.$2, endian);
      if (next.$1 != data.getUint32(offset + 16) ||
          next.$2 != data.getUint32(offset + 20)) {
        break;
      }
      sum = next;
      if (number * header.pageSize > maxImageBytes ||
          size * header.pageSize > maxImageBytes) {
        throw const FormatException('WAL image limit exceeded');
      }
      pending[number] = frame;
      if (size != 0) {
        pageCount = size;
        committed = Map.of(pending)..removeWhere((number, _) => number > size);
        pending.removeWhere((number, _) => number > size);
      }
    }
    final image = Uint8List(pageCount * header.pageSize);
    final copied =
        image.length < database.length ? image.length : database.length;
    image.setRange(0, copied, database);
    for (var number = 1; number <= pageCount; number++) {
      final page = committed[number];
      if (page != null) {
        image.setRange(
            (number - 1) * header.pageSize, number * header.pageSize, page);
      } else if (number * header.pageSize > database.length) {
        throw const FormatException('Missing WAL database page');
      }
    }
    return image;
  }

  /// Produces an independent rollback-format copy for the read-only pager.
  /// The source database/WAL files are never checkpointed or changed.
  static Uint8List rollbackCopy(Uint8List database, Uint8List wal,
      {int maxImageBytes = 64 * 1024 * 1024}) {
    final image = recover(database, wal, maxImageBytes: maxImageBytes);
    final header = DatabaseHeader.decode(image);
    image[18] = 1;
    image[19] = 1;
    final data = ByteData.sublistView(image);
    data.setUint32(28, image.length ~/ header.pageSize);
    data.setUint32(92, header.changeCounter);
    return image;
  }

  static (int, int) _checksum(Uint8List bytes, int s1, int s2, Endian endian) {
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length; i += 8) {
      s1 = (s1 + data.getUint32(i, endian) + s2) % 0x100000000;
      s2 = (s2 + data.getUint32(i + 4, endian) + s1) % 0x100000000;
    }
    return (s1, s2);
  }
}
