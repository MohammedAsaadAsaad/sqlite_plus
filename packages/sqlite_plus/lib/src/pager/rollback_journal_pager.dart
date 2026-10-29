import 'dart:math';
import 'dart:typed_data';

import 'image_pager.dart';

import '../btree/rowid_page_patch.dart';
import '../format/database_header.dart';
import '../storage/durable_storage_backend.dart';

/// Single-writer pager for pre-provisioned durable files.
///
/// A commit appends the changed byte ranges, or one logical integer addend,
/// and syncs that redo log once. The database file is written when the log
/// passes [checkpointBytes] or the pager closes. Restart applies the redo,
/// so a commit is durable before those database bytes are on disk. Durability
/// depends on [DurableStorageBackend]. No WAL, locks, concurrent readers, or
/// multi-database transactions are provided. The redo magic is not an official
/// SQLite journal header.
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
  final List<_Addend> _addends = [];
  static const checkpointBytes = 16 * 1024 * 1024;
  static const _magic = [0x53, 0x51, 0x52, 0x45, 0x44, 0x4f, 0x02, 0x00];
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
  Future<Uint8List> readImage() => _exclusive(() async => _view());

  /// A commit is durable once the redo log syncs. Database pages stay cached
  /// until checkpoint. On any I/O failure this instance is poisoned; reopen
  /// to recover.
  @override
  Future<void> commitImage(Uint8List image) => _exclusive(() async {
        if (image.length > maxImageBytes) {
          throw const FormatException('Image limit exceeded');
        }
        final header = DatabaseHeader.decode(image);
        header.validateFileLength(image.length);
        if (header.pageSize != pageSize ||
            header.readVersion != 1 ||
            header.writeVersion != 1 ||
            !header.hasValidDatabaseSize ||
            header.databaseSize * pageSize != image.length) {
          throw const FormatException('Invalid replacement database image');
        }
        if (_addends.isNotEmpty) await _checkpoint();
        final original = _cached;
        final oldPages = original.length ~/ pageSize;
        final nextPages = image.length ~/ pageSize;
        final pages = <int>[];
        final bodies = <Uint8List>[];
        final limit = oldPages < nextPages ? oldPages : nextPages;
        for (var page = 1; page <= limit; page++) {
          final body = _extent(original, image, page);
          if (body == null) continue;
          pages.add(page);
          bodies.add(body);
        }
        for (var page = oldPages + 1; page <= nextPages; page++) {
          pages.add(page);
          bodies.add(_fullPage(image, page));
        }
        if (pages.isEmpty) {
          if (image.length == original.length) {
            _cached = image;
            return;
          }
          // A shrink or grow with no changed overlapping bytes still has to
          // record the new page count on a frame.
          final page = nextPages < 1 ? 1 : nextPages;
          pages.add(page);
          bodies.add(_fullPage(image, page));
        }
        try {
          final record = _encode(pages, bodies, nextPages);
          await _append(record.bytes);
          _salt = record.salt;
          _chain = record.chain;
          _redoEnd = record.end;
          _redoOpen = true;
          _cached = image;
          if (_redoEnd > checkpointBytes) await _checkpoint();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  /// Records an integer-column addend without rewriting the leaves.
  ///
  /// The live connection keeps applying the addend. Restart applies it to the
  /// stored pages. [deltas] are stored-record slots.
  Future<void> commitAddend(int root, Map<int, BigInt> deltas) =>
      _exclusive(() async {
        if (root < 2 || deltas.isEmpty) {
          throw ArgumentError('Invalid addend commit');
        }
        final body = Uint8List(16 + deltas.length * 12);
        body[0] = 2;
        final fields = ByteData.sublistView(body);
        fields.setUint32(4, root);
        fields.setUint32(8, deltas.length);
        var cursor = 16;
        for (final entry in deltas.entries) {
          fields.setUint32(cursor, entry.key);
          final bits = entry.value.toSigned(64).toInt();
          fields.setUint32(cursor + 4, bits & 0xffffffff);
          fields.setUint32(cursor + 8, (bits >> 32) & 0xffffffff);
          cursor += 12;
        }
        try {
          final record = _encode([0], [body], _cached.length ~/ pageSize);
          await _append(record.bytes);
          _salt = record.salt;
          _chain = record.chain;
          _redoEnd = record.end;
          _redoOpen = true;
          _addends.add(_Addend(root, Map<int, BigInt>.of(deltas)));
          if (_redoEnd > checkpointBytes) await _checkpoint();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      });

  Uint8List _view() {
    var image = _cached;
    for (final addend in _addends) {
      final next = RowidPagePatch.addColumns(image, addend.root, addend.deltas);
      if (next == null) {
        throw const FormatException('Redo addend could not be applied');
      }
      image = next;
    }
    return Uint8List.fromList(image);
  }

  Uint8List? _extent(Uint8List before, Uint8List after, int page) {
    final start = (page - 1) * pageSize;
    final runs = <(int, int)>[];
    var index = 0;
    while (index < pageSize) {
      if (before[start + index] == after[start + index]) {
        index++;
        continue;
      }
      final run = index;
      while (
          index < pageSize && before[start + index] != after[start + index]) {
        index++;
      }
      runs.add((run, index - run));
    }
    if (runs.isEmpty) return null;
    var sparse = 1;
    for (final run in runs) {
      sparse += 4 + run.$2;
    }
    if (sparse >= 1 + pageSize) return _fullPage(after, page);
    final body = Uint8List(sparse);
    body[0] = 1;
    final data = ByteData.sublistView(body);
    var cursor = 1;
    for (final run in runs) {
      data.setUint16(cursor, run.$1);
      data.setUint16(cursor + 2, run.$2);
      body.setRange(cursor + 4, cursor + 4 + run.$2, after, start + run.$1);
      cursor += 4 + run.$2;
    }
    return body;
  }

  Uint8List _fullPage(Uint8List image, int page) {
    final body = Uint8List(1 + pageSize);
    body[0] = 0;
    body.setRange(1, body.length, image, (page - 1) * pageSize);
    return body;
  }

  _RedoRecord _encode(List<int> pages, List<Uint8List> bodies, int pageCount) {
    final header = _redoOpen ? 0 : _headerBytes;
    var total = header;
    for (final body in bodies) {
      total += _framePrefix + body.length;
    }
    final bytes = Uint8List(total);
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
    var cursor = header;
    for (var i = 0; i < pages.length; i++) {
      final body = bodies[i];
      final frame = ByteData.sublistView(
          bytes, cursor, cursor + _framePrefix + body.length);
      frame.setUint32(0, pages[i]);
      frame.setUint32(4, i == pages.length - 1 ? pageCount : 0);
      frame.setUint32(12, body.length);
      bytes.setRange(
          cursor + _framePrefix, cursor + _framePrefix + body.length, body);
      chain = _mix(chain, bytes, cursor, cursor + 8);
      chain =
          _mix(chain, bytes, cursor + 12, cursor + _framePrefix + body.length);
      frame.setUint32(8, chain);
      cursor += _framePrefix + body.length;
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

  Future<void> _checkpoint() async {
    if (_addends.isNotEmpty) {
      _cached = _view();
      _addends.clear();
    }
    final database = _direct(_database);
    final journal = _direct(_journal);
    if (database != null && journal != null) {
      database.writeAtSync(0, _cached);
      database.truncateAtSync(_cached.length);
      database.flushSync();
      journal.truncateAtSync(0);
      journal.flushSync();
    } else {
      await _database.write(0, _cached);
      await _database.truncate(_cached.length);
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
    final restored = _applyReplay(current, replay);
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
    final frames = <_Frame>[];
    var chain = salt;
    var offset = _headerBytes;
    var committed = 0;
    while (offset + _framePrefix <= log.length) {
      final frame = ByteData.sublistView(log, offset);
      final page = frame.getUint32(0);
      final count = frame.getUint32(4);
      final stored = frame.getUint32(8);
      final bodyLength = frame.getUint32(12);
      if (bodyLength > size + 1 ||
          offset + _framePrefix + bodyLength > log.length) {
        break;
      }
      final end = offset + _framePrefix + bodyLength;
      final next =
          _mix(_mix(chain, log, offset, offset + 8), log, offset + 12, end);
      if (stored != next || page > 0x7fffffff || count > 0x7fffffff) break;
      chain = next;
      frames.add(_Frame(
          page, Uint8List.sublistView(log, offset + _framePrefix, end),
          count: count));
      offset = end;
      if (count != 0) committed = frames.length;
    }
    if (committed == 0) return null;
    final kept = frames.sublist(0, committed);
    final pageCount = kept.last.count;
    if (pageCount < 1) return null;
    return _Replay(size, pageCount, kept);
  }

  static Uint8List _applyReplay(Uint8List current, _Replay replay) {
    var image = Uint8List.fromList(current);
    for (final frame in replay.frames) {
      if (frame.count != 0) {
        image = _fit(image, frame.count * replay.pageSize);
      } else if (frame.page > 0) {
        final need = frame.page * replay.pageSize;
        if (need > image.length) image = _fit(image, need);
      }
      if (frame.page == 0) {
        image = _applyAddend(image, frame.bytes);
      } else {
        _applyExtent(image, frame.page, frame.bytes, replay.pageSize);
      }
    }
    return image;
  }

  static Uint8List _fit(Uint8List image, int bytes) {
    if (bytes == image.length) return image;
    final resized = Uint8List(bytes);
    final count = bytes < image.length ? bytes : image.length;
    resized.setRange(0, count, image);
    return resized;
  }

  static Uint8List _applyAddend(Uint8List image, Uint8List body) {
    if (body.length < 16 || body[0] != 2) {
      throw const FormatException('Corrupt redo addend');
    }
    final fields = ByteData.sublistView(body);
    final root = fields.getUint32(4);
    final count = fields.getUint32(8);
    if (16 + count * 12 != body.length) {
      throw const FormatException('Corrupt redo addend');
    }
    final deltas = <int, BigInt>{};
    for (var i = 0; i < count; i++) {
      final cursor = 16 + i * 12;
      final slot = fields.getUint32(cursor);
      final low = fields.getUint32(cursor + 4);
      final high = fields.getUint32(cursor + 8);
      deltas[slot] = (BigInt.from(high) << 32 | BigInt.from(low)).toSigned(64);
    }
    final next = RowidPagePatch.addColumns(image, root, deltas);
    if (next == null) {
      throw const FormatException('Redo addend could not be applied');
    }
    return next;
  }

  static void _applyExtent(
      Uint8List image, int page, Uint8List body, int pageSize) {
    final start = (page - 1) * pageSize;
    if (start < 0 || start + pageSize > image.length || body.isEmpty) {
      throw const FormatException('Corrupt redo page');
    }
    if (body[0] == 0) {
      if (body.length != 1 + pageSize) {
        throw const FormatException('Corrupt redo page');
      }
      image.setRange(start, start + pageSize, body, 1);
      return;
    }
    if (body[0] != 1) throw const FormatException('Corrupt redo page');
    final data = ByteData.sublistView(body);
    var cursor = 1;
    while (cursor + 4 <= body.length) {
      final offset = data.getUint16(cursor);
      final length = data.getUint16(cursor + 2);
      cursor += 4;
      if (offset + length > pageSize || cursor + length > body.length) {
        throw const FormatException('Corrupt redo page');
      }
      image.setRange(start + offset, start + offset + length, body, cursor);
      cursor += length;
    }
    if (cursor != body.length) throw const FormatException('Corrupt redo page');
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

final class _Addend {
  _Addend(this.root, this.deltas);
  final int root;
  final Map<int, BigInt> deltas;
}
