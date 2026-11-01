import 'dart:typed_data';

import 'database_header.dart';

/// Official SQLite rollback-journal playback and encoding.
/// A journal whose first byte is 0, or whose magic does not match, is not hot.
abstract final class HotJournal {
  static const _magic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];

  static bool matchesMagic(Uint8List journal) =>
      journal.length >= _magic.length && _magicAt(journal, 0);

  /// One sector header plus a record for each old page. The checksum is
  /// [checksumInit] plus every 200th page byte, which is the pinned formula.
  static Uint8List encode({
    required List<(int, Uint8List)> pages,
    required int originalPages,
    required int sectorSize,
    required int checksumInit,
  }) {
    if (pages.isEmpty) {
      throw ArgumentError('Official journal needs a page');
    }
    final pageSize = pages.first.$2.length;
    if (originalPages < 1 ||
        sectorSize < 28 ||
        pageSize < 512 ||
        pages.any((page) => page.$2.length != pageSize)) {
      throw ArgumentError('Invalid official journal');
    }
    final bytes = Uint8List(sectorSize + pages.length * (pageSize + 8));
    bytes.setRange(0, _magic.length, _magic);
    final fields = ByteData.sublistView(bytes);
    fields.setUint32(8, pages.length);
    fields.setUint32(12, checksumInit & 0xffffffff);
    fields.setUint32(16, originalPages);
    fields.setUint32(20, sectorSize);
    fields.setUint32(24, pageSize);
    var offset = sectorSize;
    for (final page in pages) {
      fields.setUint32(offset, page.$1);
      bytes.setRange(offset + 4, offset + 4 + pageSize, page.$2);
      fields.setUint32(offset + 4 + pageSize, _checksum(page.$2, checksumInit));
      offset += pageSize + 8;
    }
    return bytes;
  }

  /// `journal_mode=persist` commits by clearing the 28-byte header.
  static void invalidateHeader(Uint8List journal) {
    final count = journal.length < 28 ? journal.length : 28;
    for (var i = 0; i < count; i++) {
      journal[i] = 0;
    }
  }

  static bool looksHot(Uint8List journal) =>
      journal.isNotEmpty && journal[0] != 0;

  /// Super-journal path stored at the end of [journal], when the trailer is
  /// well formed. A checksum mismatch returns null so playback still runs.
  static String? superJournalName(Uint8List journal) {
    if (journal.length < 16) return null;
    final data = ByteData.sublistView(journal);
    final length = data.getUint32(journal.length - 16);
    if (length == 0 || length >= 512 || length > journal.length - 16) {
      return null;
    }
    final end = journal.length - 8;
    for (var i = 0; i < _magic.length; i++) {
      if (journal[end + i] != _magic[i]) return null;
    }
    var checksum = data.getUint32(journal.length - 12);
    final start = journal.length - 16 - length;
    for (var i = 0; i < length; i++) {
      checksum = (checksum - journal[start + i]) & 0xffffffff;
    }
    if (checksum != 0) return null;
    return String.fromCharCodes(journal, start, start + length);
  }

  /// Rolled-back image. Playback truncates to the journal's original page
  /// count, then copies pages until a short read, illegal page number, or
  /// checksum mismatch. The caller's buffers are not modified.
  static Uint8List recover(Uint8List database, Uint8List journal) {
    if (!looksHot(journal) || journal.length < 28 || !_magicAt(journal, 0)) {
      return Uint8List.fromList(database);
    }
    final header = DatabaseHeader.decode(database);
    final fields = ByteData.sublistView(journal);
    final sector = fields.getUint32(20);
    final encodedPage = fields.getUint32(24);
    if (!_powerOfTwo(sector, 32, 65536) ||
        (encodedPage != 0 && !_powerOfTwo(encodedPage, 512, 65536)) ||
        journal.length < sector) {
      return Uint8List.fromList(database);
    }
    final pageSize = encodedPage == 0 ? header.pageSize : encodedPage;
    var image = Uint8List.fromList(database);
    var offset = 0;
    var headerPage = pageSize;
    var appliedTruncate = false;
    while (offset + sector <= journal.length) {
      if (!_magicAt(journal, offset)) break;
      final countField = fields.getUint32(offset + 8);
      final checksumInit = fields.getUint32(offset + 12);
      final originalPages = fields.getUint32(offset + 16);
      offset += sector;
      var count = countField;
      if (count == 0xffffffff) {
        count = (journal.length - sector) ~/ (headerPage + 8);
      }
      if (!appliedTruncate) {
        if (originalPages == 0 || originalPages > 0x7fffffff ~/ headerPage) {
          break;
        }
        final bytes = originalPages * headerPage;
        if (bytes < image.length) {
          image = Uint8List.sublistView(image, 0, bytes);
          image = Uint8List.fromList(image);
        } else if (bytes > image.length) {
          final grown = Uint8List(bytes);
          grown.setRange(0, image.length, image);
          image = grown;
        }
        appliedTruncate = true;
      }
      final record = headerPage + 8;
      final available = (journal.length - offset) ~/ record;
      if (count > available) count = available;
      final pending = (0x40000000 ~/ headerPage) + 1;
      var stop = false;
      for (var i = 0; i < count; i++) {
        final number = fields.getUint32(offset);
        final page =
            Uint8List.sublistView(journal, offset + 4, offset + 4 + headerPage);
        final stored = fields.getUint32(offset + 4 + headerPage);
        offset += record;
        if (number == 0 || number == pending) {
          stop = true;
          break;
        }
        if (_checksum(page, checksumInit) != stored) {
          stop = true;
          break;
        }
        final limit = image.length ~/ headerPage;
        if (number > limit) continue;
        image.setRange((number - 1) * headerPage, number * headerPage, page);
      }
      if (stop) break;
      if (offset == 0) break;
      final next = ((offset - 1) ~/ sector + 1) * sector;
      offset = next;
    }
    return image;
  }

  static bool _magicAt(Uint8List bytes, int offset) {
    if (offset + 8 > bytes.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[offset + i] != _magic[i]) return false;
    }
    return true;
  }

  static bool _powerOfTwo(int value, int minimum, int maximum) =>
      value >= minimum && value <= maximum && (value & (value - 1)) == 0;

  static int _checksum(Uint8List page, int seed) {
    var sum = seed & 0xffffffff;
    var index = page.length - 200;
    while (index > 0) {
      sum = (sum + page[index]) & 0xffffffff;
      index -= 200;
    }
    return sum;
  }
}
