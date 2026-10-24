import 'dart:math';
import 'dart:typed_data';

import 'image_pager.dart';

import '../format/database_header.dart';
import '../storage/durable_storage_backend.dart';

/// Single-writer, full-image rollback pager for pre-provisioned durable files.
///
/// Uses a single SQLite rollback-journal header and complete page before-images.
/// PERSIST-style invalidation retains the existing journal directory entry.
/// Durability depends on [DurableStorageBackend], not merely on this algorithm.
/// No WAL, locks, concurrent readers or multi-database transactions are provided.
final class RollbackJournalPager implements ImagePager {
  RollbackJournalPager._(
      this._database, this._journal, this.pageSize, this.maxImageBytes);
  final DurableStorageBackend _database;
  final DurableStorageBackend _journal;
  final int pageSize;
  final int maxImageBytes;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;
  static const _magic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];
  static const _sectorSize = 512;

  /// Both backends remain caller-owned if opening fails, pager-owned on success.
  static Future<RollbackJournalPager> open(
      DurableStorageBackend database, DurableStorageBackend journal,
      {int maxImageBytes = 64 * 1024 * 1024}) async {
    if (maxImageBytes < 100) throw RangeError.value(maxImageBytes);
    await _recover(database, journal, maxImageBytes);
    final image = await _all(database, maxImageBytes);
    final header = DatabaseHeader.decode(image);
    header.validateFileLength(image.length);
    if (header.readVersion != 1 ||
        header.writeVersion != 1 ||
        !header.hasValidDatabaseSize ||
        header.databaseSize * header.pageSize != image.length) {
      throw UnsupportedError(
          'Writer requires a complete rollback-format database image');
    }
    return RollbackJournalPager._(
        database, journal, header.pageSize, maxImageBytes);
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    if (_closed || _failed) {
      throw StateError('Pager closed or requires recovery');
    }
    if (_busy) throw StateError('Concurrent pager operation');
    _busy = true;
    try {
      return await body();
    } finally {
      _busy = false;
    }
  }

  @override
  Future<Uint8List> readImage() =>
      _exclusive(() => _all(_database, maxImageBytes));

  /// A commit is acknowledged only after database sync and journal invalidation
  /// sync. On any I/O failure this instance is poisoned; reopen to recover.
  @override
  Future<void> commitImage(Uint8List image) => _exclusive(() async {
        final next = Uint8List.fromList(image);
        if (next.length > maxImageBytes) {
          throw const FormatException('Image limit exceeded');
        }
        final header = DatabaseHeader.decode(next);
        header.validateFileLength(next.length);
        if (header.pageSize != pageSize ||
            header.readVersion != 1 ||
            header.writeVersion != 1 ||
            !header.hasValidDatabaseSize ||
            header.databaseSize * pageSize != next.length) {
          throw const FormatException('Invalid replacement database image');
        }
        try {
          final original = await _all(_database, maxImageBytes);
          final pages = original.length ~/ pageSize;
          final random = Random.secure();
          final seed = random.nextInt(65536) * 65536 + random.nextInt(65536);
          // An invalid header is made durable before reusing the journal.
          await _journal.write(0, Uint8List(_sectorSize));
          await _journal.truncate(_sectorSize);
          await _journal.sync();
          for (var page = 1; page <= pages; page++) {
            final bytes = Uint8List.sublistView(
                original, (page - 1) * pageSize, page * pageSize);
            final record = Uint8List(pageSize + 8);
            final data = ByteData.sublistView(record);
            data.setUint32(0, page);
            record.setRange(4, pageSize + 4, bytes);
            data.setUint32(pageSize + 4, _checksum(bytes, seed));
            await _journal.write(
                _sectorSize + (page - 1) * record.length, record);
          }
          await _journal.sync();
          final journalHeader = Uint8List(28)..setRange(0, 8, _magic);
          final fields = ByteData.sublistView(journalHeader);
          fields.setUint32(8, pages);
          fields.setUint32(12, seed);
          fields.setUint32(16, pages);
          fields.setUint32(20, _sectorSize);
          fields.setUint32(24, pageSize);
          await _journal.write(0, journalHeader);
          await _journal.sync();
          await _database.write(0, next);
          await _database.truncate(next.length);
          await _database.sync();
          await _journal.write(0, Uint8List(28));
          await _journal.sync();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  static int _checksum(Uint8List page, int seed) {
    var result = seed;
    for (var i = page.length - 200; i > 0; i -= 200) {
      result = (result + page[i]) % 0x100000000;
    }
    return result;
  }

  static Future<void> _recover(DurableStorageBackend database,
      DurableStorageBackend journal, int maxImageBytes) async {
    final length = await journal.length();
    if (length == 0) return;
    final first = await _read(journal, 0, min(28, length));
    // An invalidated PERSIST journal is not hot. A partial valid magic is not
    // enough to authorize restoring database bytes.
    if (first.every((byte) => byte == 0)) return;
    if (first.length != 28 ||
        !List.generate(8, (i) => first[i] == _magic[i]).every((v) => v)) {
      throw const FormatException('Unrecognized or torn journal header');
    }
    final fields = ByteData.sublistView(first);
    final count = fields.getUint32(8);
    final seed = fields.getUint32(12);
    final pages = fields.getUint32(16);
    final sector = fields.getUint32(20);
    final size = fields.getUint32(24);
    if (count == 0 ||
        count != pages ||
        sector != _sectorSize ||
        size < 512 ||
        size > 65536 ||
        (size & (size - 1)) != 0 ||
        pages * size > maxImageBytes ||
        sector + count * (size + 8) != length) {
      throw const FormatException('Unsupported or incomplete journal');
    }
    // Validate the entire journal before changing any database bytes.
    final original = Uint8List(pages * size);
    final seen = <int>{};
    for (var i = 0; i < count; i++) {
      final record = await _read(journal, sector + i * (size + 8), size + 8);
      final data = ByteData.sublistView(record);
      final number = data.getUint32(0);
      final page = Uint8List.sublistView(record, 4, size + 4);
      if (number < 1 ||
          number > pages ||
          !seen.add(number) ||
          data.getUint32(size + 4) != _checksum(page, seed)) {
        throw const FormatException('Corrupt journal page or checksum');
      }
      original.setRange((number - 1) * size, number * size, page);
    }
    final header = DatabaseHeader.decode(original);
    if (header.pageSize != size) {
      throw const FormatException('Journal page size mismatch');
    }
    header.validateFileLength(original.length);
    await database.write(0, original);
    await database.truncate(original.length);
    await database.sync();
    await journal.write(0, Uint8List(28));
    await journal.sync();
  }

  static Future<Uint8List> _all(
      DurableStorageBackend storage, int limit) async {
    final size = await storage.length();
    if (size < 0 || size > limit) {
      throw const FormatException('Image limit exceeded');
    }
    return _read(storage, 0, size);
  }

  static Future<Uint8List> _read(
      DurableStorageBackend storage, int offset, int length) async {
    final result = Uint8List(length);
    var read = 0;
    while (read < length) {
      final count = await storage.read(
          offset + read, Uint8List.sublistView(result, read));
      if (count <= 0 || count > length - read) {
        throw const FormatException('Truncated journal/database');
      }
      read += count;
    }
    return result;
  }

  @override
  Future<void> close() async {
    if (_busy) throw StateError('Pager operation in progress');
    if (_closed) return;
    _closed = true;
    try {
      await _database.close();
    } finally {
      await _journal.close();
    }
  }
}
