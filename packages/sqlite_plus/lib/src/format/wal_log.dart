import 'dart:typed_data';

/// Internal shared WAL framing codec. Header/frame integers are big endian;
/// checksum words follow the endian bit in the WAL magic.
final class WalLog {
  WalLog._(this.endian, this.salt1, this.salt2, this.committedEnd,
      this.checksum, this.databasePages, this.pages);
  final Endian endian;
  final int salt1;
  final int salt2;
  final int committedEnd;
  final (int, int) checksum;
  final int? databasePages;
  final Map<int, Uint8List> pages;

  static WalLog decode(Uint8List wal, int pageSize, int maxImageBytes) {
    if (wal.length < 32) throw const FormatException('Truncated WAL header');
    final data = ByteData.sublistView(wal);
    final magic = data.getUint32(0);
    if (![0x377f0682, 0x377f0683].contains(magic) ||
        data.getUint32(4) != 3007000 ||
        data.getUint32(8) != pageSize) {
      throw const FormatException('Invalid WAL header');
    }
    final endian = magic == 0x377f0682 ? Endian.little : Endian.big;
    var sum = walChecksum(Uint8List.sublistView(wal, 0, 24), (0, 0), endian);
    if (sum.$1 != data.getUint32(24) || sum.$2 != data.getUint32(28)) {
      throw const FormatException('Invalid WAL header checksum');
    }
    final salt1 = data.getUint32(16);
    final salt2 = data.getUint32(20);
    final pending = <int, Uint8List>{};
    var committed = <int, Uint8List>{};
    var end = 32;
    var committedSum = sum;
    int? pageCount;
    final stride = 24 + pageSize;
    for (var offset = 32; offset + stride <= wal.length; offset += stride) {
      final number = data.getUint32(offset);
      final size = data.getUint32(offset + 4);
      if (number == 0 ||
          data.getUint32(offset + 8) != salt1 ||
          data.getUint32(offset + 12) != salt2) {
        break;
      }
      final frame = Uint8List.sublistView(wal, offset + 24, offset + stride);
      final next = walChecksum(
          frame,
          walChecksum(
              Uint8List.sublistView(wal, offset, offset + 8), sum, endian),
          endian);
      if (next.$1 != data.getUint32(offset + 16) ||
          next.$2 != data.getUint32(offset + 20)) {
        break;
      }
      if (number * pageSize > maxImageBytes ||
          size * pageSize > maxImageBytes) {
        throw const FormatException('WAL image limit exceeded');
      }
      sum = next;
      pending[number] = frame;
      if (size != 0) {
        pageCount = size;
        pending.removeWhere((number, _) => number > size);
        committed = Map.of(pending);
        end = offset + stride;
        committedSum = sum;
      }
    }
    return WalLog._(endian, salt1, salt2, end, committedSum, pageCount,
        Map.unmodifiable(committed));
  }
}

(int, int) walChecksum(Uint8List bytes, (int, int) initial, Endian endian) {
  final data = ByteData.sublistView(bytes);
  var s1 = initial.$1;
  var s2 = initial.$2;
  for (var i = 0; i < bytes.length; i += 8) {
    s1 = (s1 + data.getUint32(i, endian) + s2) % 0x100000000;
    s2 = (s2 + data.getUint32(i + 4, endian) + s1) % 0x100000000;
  }
  return (s1, s2);
}
