import 'dart:io';
import 'dart:typed_data';

import 'durable_storage_backend.dart';

/// Read/write access to an EXISTING, durably provisioned regular file.
///
/// Caller must attest directory-entry durability, exclude other processes and
/// renames/removals, and keep database/journal as distinct files. This adapter
/// never creates/replaces/deletes files and cannot provision their directory
/// entries. FileMode.append permits random positioning without initial truncate.
final class DurableFileStorageBackend implements DurableStorageBackend {
  DurableFileStorageBackend._(this._file);
  final RandomAccessFile _file;
  Future<void> _pending = Future.value();
  bool _closed = false;
  String? _lockPath;
  static final Set<String> _leases = {};

  /// Exclusive SQLite lock-byte-range lease for a single owning Dart isolate.
  /// On POSIX, ANY other descriptor close can drop process locks, and other
  /// isolates can obtain overlapping locks. All handles in a process must be
  /// coordinated by one owner; this is not a general cross-isolate lock manager.
  static Future<DurableFileStorageBackend> openExclusive(String path,
      {required bool directoryEntryIsDurable}) async {
    final canonical = await File(path).resolveSymbolicLinks();
    if (!_leases.add(canonical)) {
      throw StateError('Database already leased in this isolate');
    }
    DurableFileStorageBackend? storage;
    try {
      storage = await openExisting(canonical,
          directoryEntryIsDurable: directoryEntryIsDurable);
      await storage._file.lock(FileLock.exclusive, 0x40000000, 0x40000200);
      storage._lockPath = canonical;
      return storage;
    } catch (_) {
      _leases.remove(canonical);
      await storage?.close();
      rethrow;
    }
  }

  static Future<DurableFileStorageBackend> openExisting(String path,
      {required bool directoryEntryIsDurable}) async {
    if (!directoryEntryIsDurable) {
      throw UnsupportedError('A durably provisioned existing file is required');
    }
    if ((await File(path).stat()).type != FileSystemEntityType.file) {
      throw FileSystemException('Existing regular file required', path);
    }
    return DurableFileStorageBackend._(
        await File(path).open(mode: FileMode.append));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pending.then((_) async {
      if (_closed) throw StateError('Storage closed');
      return operation();
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  Future<int> read(int offset, Uint8List buffer) => _serialize(() async {
        if (offset < 0) throw RangeError.value(offset);
        await _file.setPosition(offset);
        return _file.readInto(buffer);
      });
  @override
  Future<void> write(int offset, Uint8List bytes) => _serialize(() async {
        if (offset < 0) throw RangeError.value(offset);
        await _file.setPosition(offset);
        await _file.writeFrom(bytes);
      });
  @override
  Future<void> truncate(int size) => _serialize(() async {
        if (size < 0) throw RangeError.value(size);
        await _file.truncate(size);
      });
  @override
  Future<int> length() => _serialize(_file.length);
  @override
  Future<void> sync() => _serialize(() async {
        await _file.flush();
      });
  @override
  Future<void> close() {
    final result = _pending.then((_) async {
      if (_closed) return;
      _closed = true;
      try {
        if (_lockPath != null) await _file.unlock(0x40000000, 0x40000200);
      } finally {
        try {
          await _file.close();
        } finally {
          if (_lockPath != null) _leases.remove(_lockPath);
        }
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
