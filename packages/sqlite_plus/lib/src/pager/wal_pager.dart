import 'dart:math';
import 'dart:typed_data';

import '../format/database_header.dart';
import '../format/wal_log.dart';
import '../format/wal_snapshot.dart';
import '../storage/durable_storage_backend.dart';
import 'image_pager.dart';

/// Full-image WAL writer/checkpointer under exclusive ownership. The main file
/// must already use WAL format. External readers/writers and stale -shm files
/// must be excluded; this class does not maintain SQLite's shared wal-index.
final class WalPager implements ImagePager {
  WalPager._(this._database, this._wal, this.pageSize, this.maxImageBytes,
      this.maxWalBytes);
  final DurableStorageBackend _database;
  final DurableStorageBackend _wal;
  final int pageSize;
  final int maxImageBytes;
  final int maxWalBytes;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;

  static Future<WalPager> open(
      DurableStorageBackend database, DurableStorageBackend wal,
      {required bool exclusiveOwnership,
      required bool walIndexAbsent,
      int maxImageBytes = 64 * 1024 * 1024,
      int maxWalBytes = 256 * 1024 * 1024}) async {
    if (!exclusiveOwnership || !walIndexAbsent) {
      throw UnsupportedError(
          'WAL requires exclusive ownership without a shared wal-index');
    }
    if (identical(database, wal)) {
      throw ArgumentError('Distinct database and WAL required');
    }
    if (maxImageBytes < 512 || maxWalBytes < 32) {
      throw RangeError('Invalid WAL bounds');
    }
    final main = await _all(database, maxImageBytes);
    final header = DatabaseHeader.decode(main);
    if (header.readVersion != 2 || header.writeVersion != 2) {
      throw UnsupportedError(
          'Pre-provision a WAL-format database before opening the WAL writer');
    }
    final log = await _all(wal, maxWalBytes);
    final image =
        WalSnapshot.rollbackCopy(main, log, maxImageBytes: maxImageBytes);
    DatabaseHeader.decode(image).validateFileLength(image.length);
    return WalPager._(
        database, wal, header.pageSize, maxImageBytes, maxWalBytes);
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_closed || _failed || _busy) {
      throw StateError('WAL pager closed, poisoned or busy');
    }
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  @override
  Future<Uint8List> readImage() =>
      _exclusive(() async => WalSnapshot.rollbackCopy(
          await _all(_database, maxImageBytes), await _all(_wal, maxWalBytes),
          maxImageBytes: maxImageBytes));

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
          throw const FormatException('Invalid WAL replacement image');
        }
        var bytes = await _all(_wal, maxWalBytes);
        final pages = next.length ~/ pageSize;
        final existing = bytes.isEmpty
            ? null
            : WalLog.decode(bytes, pageSize, maxImageBytes);
        final end = existing?.committedEnd ?? 32;
        if (end + pages * (pageSize + 24) > maxWalBytes) {
          throw StateError('WAL limit reached; checkpoint before committing');
        }
        next[18] = 2;
        next[19] = 2;
        try {
          if (bytes.isEmpty) {
            bytes = Uint8List(32);
            final data = ByteData.sublistView(bytes);
            final random = Random.secure();
            data.setUint32(0, 0x377f0682);
            data.setUint32(4, 3007000);
            data.setUint32(8, pageSize);
            data.setUint32(
                16, random.nextInt(65536) * 65536 + random.nextInt(65536));
            data.setUint32(
                20, random.nextInt(65536) * 65536 + random.nextInt(65536));
            final sum = walChecksum(
                Uint8List.sublistView(bytes, 0, 24), (0, 0), Endian.little);
            data.setUint32(24, sum.$1);
            data.setUint32(28, sum.$2);
            await _wal.write(0, bytes);
            await _wal.sync();
          }
          final state = WalLog.decode(bytes, pageSize, maxImageBytes);
          // Discard a torn/uncommitted suffix before appending a new transaction.
          await _wal.truncate(state.committedEnd);
          await _wal.sync();
          var sum = state.checksum;
          for (var number = 1; number <= pages; number++) {
            final frame = Uint8List(pageSize + 24);
            final data = ByteData.sublistView(frame);
            data.setUint32(0, number);
            data.setUint32(4, number == pages ? pages : 0);
            data.setUint32(8, state.salt1);
            data.setUint32(12, state.salt2);
            frame.setRange(24, frame.length, next, (number - 1) * pageSize);
            sum = walChecksum(
                Uint8List.sublistView(frame, 24),
                walChecksum(
                    Uint8List.sublistView(frame, 0, 8), sum, state.endian),
                state.endian);
            data.setUint32(16, sum.$1);
            data.setUint32(20, sum.$2);
            await _wal.write(
                state.committedEnd + (number - 1) * frame.length, frame);
          }
          await _wal.sync();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  /// No readers exist under this ownership contract. Make the WAL durable first,
  /// then copy committed pages to main, sync main, and finally clear/sync WAL.
  /// Restart can replay the retained WAL after a crash anywhere in the copy.
  Future<void> checkpoint() => _exclusive(() async {
        final log = await _all(_wal, maxWalBytes);
        if (log.isEmpty) return;
        final main = await _all(_database, maxImageBytes);
        final image =
            WalSnapshot.recover(main, log, maxImageBytes: maxImageBytes);
        final header = DatabaseHeader.decode(image);
        final fields = ByteData.sublistView(image);
        fields.setUint32(28, image.length ~/ pageSize);
        fields.setUint32(92, header.changeCounter);
        try {
          await _wal.sync();
          for (var offset = 0; offset < image.length; offset += pageSize) {
            await _database.write(offset,
                Uint8List.sublistView(image, offset, offset + pageSize));
          }
          await _database.truncate(image.length);
          await _database.sync();
          await _wal.truncate(0);
          await _wal.sync();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  static Future<Uint8List> _all(
      DurableStorageBackend storage, int limit) async {
    final length = await storage.length();
    if (length < 0 || length > limit) {
      throw const FormatException('Storage limit exceeded');
    }
    final bytes = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final count =
          await storage.read(offset, Uint8List.sublistView(bytes, offset));
      if (count <= 0 || count > length - offset) {
        throw const FormatException('Short WAL/database read');
      }
      offset += count;
    }
    return bytes;
  }

  @override
  Future<void> close() async {
    if (_busy) throw StateError('WAL operation in progress');
    if (_closed) return;
    _closed = true;
    try {
      await _database.close();
    } finally {
      await _wal.close();
    }
  }
}
