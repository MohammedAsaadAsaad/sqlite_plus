import 'dart:io';
import 'dart:typed_data';

import 'storage_backend.dart';

/// Read-only file access, with serialized seek/read operations. No file locking;
/// callers must supply a stable copy without a hot journal or uncheckpointed WAL.
final class ReadOnlyFileStorageBackend implements StorageBackend {
  ReadOnlyFileStorageBackend._(this._file);
  final RandomAccessFile _file;
  Future<void> _pending = Future.value();
  bool _closed = false;

  static Future<ReadOnlyFileStorageBackend> open(String path) async =>
      ReadOnlyFileStorageBackend._(await File(path).open(mode: FileMode.read));

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
        await _file.setPosition(offset);
        return _file.readInto(buffer);
      });

  @override
  Future<int> length() => _serialize(_file.length);

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
      await _file.close();
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
