import 'dart:math';
import 'dart:typed_data';

import 'image_pager.dart';

import '../format/database_header.dart';
import '../storage/durable_storage_backend.dart';

/// Single-writer pager for pre-provisioned durable files.
///
/// A commit appends after-images of the pages it changed, syncs that redo log
/// once, then writes those pages into the database file. Restart overlays a
/// valid redo onto the database, so the database sync can wait until the log
/// passes [checkpointBytes] or the pager closes. Durability depends on
/// [DurableStorageBackend]. No WAL, locks, concurrent readers, or
/// multi-database transactions are provided.
final class RollbackJournalPager implements ImagePager {
  RollbackJournalPager._(this._database, this._journal, this.pageSize,
      this.maxImageBytes, this._cached);
  final DurableStorageBackend _database;
  final DurableStorageBackend _journal;
  final int pageSize;
  final int maxImageBytes;
  Uint8List _cached;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;
  int _redoEnd = 0;
  int _chain = 0;
  int _salt = 0;
  bool _redoOpen = false;
  static const checkpointBytes = 256 * 1024;
  static const _magic = [0x53, 0x51, 0x52, 0x45, 0x44, 0x4f, 0x01, 0x00];
  static const _headerBytes = 32;
  static const _framePrefix = 16;

  /// Both backends remain caller-owned if opening fails, pager-owned on success.
  static Future<RollbackJournalPager> open(
      DurableStorageBackend database, DurableStorageBackend journal,
      {int maxImageBytes = 64 * 1024 * 1024}) async {
    if (maxImageBytes < 100) throw RangeError.value(maxImageBytes);
    await _recover(database, journal, maxImageBytes);
    final image = Uint8List.fromList(await _all(database, maxImageBytes));
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
        database, journal, header.pageSize, maxImageBytes, image);
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
      _exclusive(() async => Uint8List.fromList(_cached));

  /// A commit is durable once the redo log syncs. Database pages are written
  /// before the call returns and synced when the log is checkpointed. On any
  /// I/O failure this instance is poisoned; reopen to recover.
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
        final original = _cached;
        final oldPages = original.length ~/ pageSize;
        final nextPages = next.length ~/ pageSize;
        final changed = <int>[];
        final limit = oldPages < nextPages ? oldPages : nextPages;
        for (var page = 1; page <= limit; page++) {
          final start = (page - 1) * pageSize;
          var same = true;
          final width = pageSize ~/ 8;
          if (width > 0 && pageSize % 8 == 0) {
            final before =
                ByteData.sublistView(original, start, start + pageSize);
            final after = ByteData.sublistView(next, start, start + pageSize);
            for (var i = 0; i < width; i++) {
              if (before.getUint64(i * 8) != after.getUint64(i * 8)) {
                same = false;
                break;
              }
            }
          } else {
            for (var i = 0; i < pageSize; i++) {
              if (original[start + i] != next[start + i]) {
                same = false;
                break;
              }
            }
          }
          if (!same) changed.add(page);
        }
        for (var page = oldPages + 1; page <= nextPages; page++) {
          changed.add(page);
        }
        if (changed.isEmpty && next.length == original.length) return;
        try {
          final record = _encode(next, changed, nextPages);
          await _append(record.bytes);
          _salt = record.salt;
          _chain = record.chain;
          _redoEnd = record.end;
          _redoOpen = true;
          await _install(next, changed, oldPages, nextPages);
          _cached = next;
          if (_redoEnd > checkpointBytes) await _checkpoint();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  _RedoRecord _encode(Uint8List next, List<int> pages, int pageCount) {
    final frameBytes = _framePrefix + pageSize;
    final header = _redoOpen ? 0 : _headerBytes;
    final bytes = Uint8List(header + pages.length * frameBytes);
    var salt = _salt;
    var chain = _chain;
    if (!_redoOpen) {
      salt = Random().nextInt(0x3fffffff) + 1;
      bytes.setRange(0, 8, _magic);
      final fields = ByteData.sublistView(bytes);
      fields.setUint32(8, pageSize);
      fields.setUint32(12, salt);
      fields.setUint32(16, _headerSum(bytes, salt));
      chain = salt;
    }
    for (var i = 0; i < pages.length; i++) {
      final offset = header + i * frameBytes;
      final frame = ByteData.sublistView(bytes, offset, offset + frameBytes);
      final page = pages[i];
      final count = i == pages.length - 1 ? pageCount : 0;
      frame.setUint32(0, page);
      frame.setUint32(4, count);
      bytes.setRange(offset + _framePrefix, offset + frameBytes, next,
          (page - 1) * pageSize);
      chain = _mix(chain, bytes, offset, offset + 8);
      chain = _mix(chain, bytes, offset + _framePrefix, offset + frameBytes);
      frame.setUint32(8, chain);
    }
    return _RedoRecord(bytes, salt, chain, _redoEnd + bytes.length);
  }

  Future<void> _append(Uint8List bytes) async {
    final journal = _direct(_journal);
    if (journal != null && _direct(_database) != null) {
      journal.writeAtSync(_redoEnd, bytes);
      journal.flushSync();
      return;
    }
    await _journal.write(_redoEnd, bytes);
    await _journal.sync();
  }

  Future<void> _install(
      Uint8List next, List<int> pages, int oldPages, int nextPages) async {
    final database = _direct(_database);
    if (database != null) {
      for (final page in pages) {
        if (page > nextPages) continue;
        database.writeAtSync(
            (page - 1) * pageSize,
            Uint8List.sublistView(
                next, (page - 1) * pageSize, page * pageSize));
      }
      if (nextPages != oldPages) database.truncateAtSync(next.length);
      return;
    }
    for (final page in pages) {
      if (page > nextPages) continue;
      await _database.write((page - 1) * pageSize,
          Uint8List.sublistView(next, (page - 1) * pageSize, page * pageSize));
    }
    if (nextPages != oldPages) await _database.truncate(next.length);
  }

  Future<void> _checkpoint() async {
    final database = _direct(_database);
    final journal = _direct(_journal);
    if (database != null && journal != null) {
      database.flushSync();
      journal.truncateAtSync(0);
      journal.flushSync();
    } else {
      await _database.sync();
      await _journal.truncate(0);
      await _journal.sync();
    }
    _redoOpen = false;
    _redoEnd = 0;
    _chain = 0;
    _salt = 0;
  }

  DirectDurableIO? _direct(DurableStorageBackend storage) =>
      storage is DirectDurableIO ? storage as DirectDurableIO : null;

  static int _headerSum(Uint8List bytes, int salt) =>
      _mix(_mix(salt, bytes, 0, 16), bytes, 20, _headerBytes);

  static int _mix(int seed, Uint8List bytes, int start, int end) {
    var sum = seed & 0xffffffff;
    for (var i = start; i < end; i++) {
      sum = (sum + bytes[i] + 1) * 131 & 0xffffffff;
    }
    return sum;
  }

  static Future<void> _recover(DurableStorageBackend database,
      DurableStorageBackend journal, int maxImageBytes) async {
    final length = await journal.length();
    if (length == 0) return;
    final log = await _all(journal, maxImageBytes);
    if (log.every((byte) => byte == 0)) return;
    final replay = _decodeRedo(log);
    if (replay == null) return;
    final current = await _all(database, maxImageBytes);
    final restored = Uint8List(replay.pageCount * replay.pageSize);
    final prefix =
        current.length < restored.length ? current.length : restored.length;
    restored.setRange(0, prefix, current);
    for (final frame in replay.frames) {
      final start = (frame.page - 1) * replay.pageSize;
      restored.setRange(start, start + replay.pageSize, frame.bytes);
    }
    final header = DatabaseHeader.decode(restored);
    if (header.pageSize != replay.pageSize) {
      throw const FormatException('Redo page size mismatch');
    }
    header.validateFileLength(restored.length);
    await database.write(0, restored);
    await database.truncate(restored.length);
    await database.sync();
    await journal.truncate(0);
    await journal.sync();
  }

  /// A bad tail is an unfinished append. A bad header is not a redo log.
  static _Replay? _decodeRedo(Uint8List log) {
    if (log.length < _headerBytes) {
      throw const FormatException('Unrecognized or torn journal header');
    }
    for (var i = 0; i < 8; i++) {
      if (log[i] != _magic[i]) {
        throw const FormatException('Unrecognized or torn journal header');
      }
    }
    final fields = ByteData.sublistView(log);
    final size = fields.getUint32(8);
    final salt = fields.getUint32(12);
    if (size < 512 ||
        size > 65536 ||
        (size & (size - 1)) != 0 ||
        fields.getUint32(16) != _headerSum(log, salt)) {
      throw const FormatException('Unrecognized or torn journal header');
    }
    final frameBytes = _framePrefix + size;
    final frames = <_Frame>[];
    var chain = salt;
    var offset = _headerBytes;
    var committed = 0;
    while (offset + frameBytes <= log.length) {
      final frame = ByteData.sublistView(log, offset, offset + frameBytes);
      final page = frame.getUint32(0);
      final count = frame.getUint32(4);
      final stored = frame.getUint32(8);
      final next = _mix(_mix(chain, log, offset, offset + 8), log,
          offset + _framePrefix, offset + frameBytes);
      if (stored != next || page < 1 || count > 0x7fffffff) break;
      chain = next;
      frames.add(_Frame(
          page,
          Uint8List.sublistView(
              log, offset + _framePrefix, offset + frameBytes),
          count: count));
      offset += frameBytes;
      if (count != 0) committed = frames.length;
    }
    if (committed == 0) return null;
    final kept = frames.sublist(0, committed);
    final pageCount = kept.last.count;
    if (pageCount < 1) return null;
    for (final frame in kept) {
      if (frame.page > pageCount) {
        throw const FormatException('Corrupt redo page');
      }
    }
    return _Replay(size, pageCount, kept);
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
    try {
      if (!_failed && _redoOpen) await _checkpoint();
    } finally {
      _closed = true;
      try {
        await _database.close();
      } finally {
        await _journal.close();
      }
    }
  }
}

final class _RedoRecord {
  _RedoRecord(this.bytes, this.salt, this.chain, this.end);
  final Uint8List bytes;
  final int salt;
  final int chain;
  final int end;
}

final class _Frame {
  _Frame(this.page, this.bytes, {this.count = 0});
  final int page;
  final Uint8List bytes;
  final int count;
}

final class _Replay {
  _Replay(this.pageSize, this.pageCount, this.frames);
  final int pageSize;
  final int pageCount;
  final List<_Frame> frames;
}
