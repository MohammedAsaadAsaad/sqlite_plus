import 'dart:io';
import 'dart:typed_data';

import '../format/hot_journal.dart';
import '../format/wal_snapshot.dart';
import '../sql/tokenizer.dart';
import 'storage_backend.dart';

/// Byte ranges SQLite locks. Rollback locks are in the database file.
/// WAL locks are in the `-shm` file, starting at byte 120.
abstract final class SqliteLock {
  static const pendingByte = 0x40000000;
  static const reservedByte = pendingByte + 1;
  static const sharedFirst = pendingByte + 2;
  static const sharedCount = 510;
  static const walRead = 123;
  static const walReadCount = 5;
}

/// Read-only open of an official SQLite file.
///
/// A shared lock is held until close. A pending WAL or a hot journal is
/// recovered in memory and the file bytes are left unchanged. A rollback
/// file with no sidecar is streamed. Failed opens close the file.
final class OfficialFileStorage implements StorageBackend {
  OfficialFileStorage._(this._file, this._image, this._shm, this._walLock);
  final RandomAccessFile _file;
  final Uint8List? _image;
  final RandomAccessFile? _shm;
  final int? _walLock;
  Future<void> _pending = Future.value();
  bool _closed = false;

  static Future<OfficialFileStorage> open(String path,
      {int maxImageBytes = 64 * 1024 * 1024}) async {
    if (maxImageBytes < 100) throw RangeError.value(maxImageBytes);
    RandomAccessFile? file;
    RandomAccessFile? shm;
    int? walLock;
    var writable = true;
    try {
      try {
        file = await File(path).open(mode: FileMode.append);
      } on FileSystemException {
        writable = false;
        file = await File(path).open(mode: FileMode.read);
      }
      if (!await _tryLock(file, FileLock.shared, SqliteLock.sharedFirst,
          SqliteLock.sharedFirst + 1)) {
        throw const SqlException('database is locked');
      }
      final length = await file.length();
      Uint8List? image;
      final journalFile = File('$path-journal');
      if (journalFile.existsSync() && writable) {
        final journal = await journalFile.readAsBytes();
        if (HotJournal.looksHot(journal) &&
            await _tryLock(file, FileLock.exclusive, SqliteLock.reservedByte,
                SqliteLock.reservedByte + 1)) {
          try {
            final superName = HotJournal.superJournalName(journal);
            final blocked = superName != null && !File(superName).existsSync();
            if (!blocked) {
              if (length > maxImageBytes) {
                throw const FormatException('Image limit exceeded');
              }
              image =
                  HotJournal.recover(await _readFully(file, length), journal);
            }
          } finally {
            await file.unlock(
                SqliteLock.reservedByte, SqliteLock.reservedByte + 1);
          }
        }
      }
      final walFile = File('$path-wal');
      if (walFile.existsSync()) {
        final shmFile = File('$path-shm');
        // A live SQLite connection keeps the locks in `-shm`. Creating that
        // file would change the sidecar set, so a leftover WAL with no
        // `-shm` is recovered without one.
        if (shmFile.existsSync()) {
          shm = await shmFile.open(mode: FileMode.read);
          for (var byte = SqliteLock.walRead;
              byte < SqliteLock.walRead + SqliteLock.walReadCount;
              byte++) {
            if (await _tryLock(shm, FileLock.shared, byte, byte + 1)) {
              walLock = byte;
              break;
            }
          }
          if (walLock == null) {
            throw const SqlException('database is locked');
          }
        }
        final wal = await walFile.readAsBytes();
        final base = image ?? await _readFully(file, length);
        if (base.length > maxImageBytes) {
          throw const FormatException('Image limit exceeded');
        }
        image = WalSnapshot.recover(base, wal, maxImageBytes: maxImageBytes);
      }
      return OfficialFileStorage._(file, image, shm, walLock);
    } catch (_) {
      if (shm != null) {
        try {
          if (walLock != null) {
            await shm.unlock(walLock, walLock + 1);
          }
        } catch (_) {}
        await shm.close();
      }
      if (file != null) {
        try {
          await file.unlock(SqliteLock.sharedFirst, SqliteLock.sharedFirst + 1);
        } catch (_) {}
        await file.close();
      }
      rethrow;
    }
  }

  static Future<bool> _tryLock(
      RandomAccessFile file, FileLock mode, int start, int end) async {
    try {
      await file.lock(mode, start, end);
      return true;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 11 || code == 13 || code == 35) return false;
      rethrow;
    }
  }

  static Future<Uint8List> _readFully(RandomAccessFile file, int length) async {
    final bytes = Uint8List(length);
    var read = 0;
    while (read < length) {
      await file.setPosition(read);
      final count = await file.readInto(Uint8List.sublistView(bytes, read));
      if (count <= 0) break;
      read += count;
    }
    if (read != length) {
      throw const FormatException('Truncated database read');
    }
    return bytes;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pending.then((_) async {
      if (_closed) throw StateError('Storage is closed');
      return operation();
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  Future<int> read(int offset, Uint8List buffer) => _serialize(() async {
        if (offset < 0) throw RangeError.value(offset, 'offset');
        final image = _image;
        if (image != null) {
          if (offset >= image.length) return 0;
          final count = buffer.length < image.length - offset
              ? buffer.length
              : image.length - offset;
          buffer.setRange(0, count, image, offset);
          return count;
        }
        await _file.setPosition(offset);
        return _file.readInto(buffer);
      });

  @override
  Future<int> length() =>
      _serialize(() async => _image?.length ?? _file.length());

  @override
  Future<void> write(int offset, Uint8List bytes) async =>
      throw UnsupportedError('Read-only storage');

  @override
  Future<void> truncate(int size) async =>
      throw UnsupportedError('Read-only storage');

  @override
  Future<void> sync() => _serialize(() async {});

  @override
  Future<void> close() {
    final result = _pending.then((_) async {
      if (_closed) return;
      _closed = true;
      try {
        final walLock = _walLock;
        if (walLock != null) {
          await _shm!.unlock(walLock, walLock + 1);
        }
        await _shm?.close();
        await _file.unlock(SqliteLock.sharedFirst, SqliteLock.sharedFirst + 1);
      } finally {
        await _file.close();
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
