import 'dart:typed_data';

import 'storage_backend.dart';

/// A private, non-durable byte store. Not a SQLite database or transaction pager.
final class MemoryStorageBackend implements StorageBackend {
  Uint8List _bytes = Uint8List(0);
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw StateError('Storage is closed');
  }

  void _checkOffset(int offset) {
    if (offset < 0) throw RangeError.value(offset, 'offset');
  }

  @override
  Future<int> read(int offset, Uint8List buffer) async {
    _ensureOpen();
    _checkOffset(offset);
    if (offset >= _bytes.length) return 0;
    final count = buffer.length < _bytes.length - offset
        ? buffer.length
        : _bytes.length - offset;
    buffer.setRange(0, count, _bytes, offset);
    return count;
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    _ensureOpen();
    _checkOffset(offset);
    final end = offset + bytes.length;
    if (end < offset) throw RangeError('Invalid write range');
    if (end > _bytes.length) {
      final grown = Uint8List(end);
      grown.setRange(0, _bytes.length, _bytes);
      _bytes = grown;
    }
    _bytes.setRange(offset, end, bytes);
  }

  @override
  Future<void> truncate(int size) async {
    _ensureOpen();
    if (size < 0) throw RangeError.value(size, 'size');
    final resized = Uint8List(size);
    final copied = size < _bytes.length ? size : _bytes.length;
    resized.setRange(0, copied, _bytes);
    _bytes = resized;
  }

  @override
  Future<int> length() async {
    _ensureOpen();
    return _bytes.length;
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
  }

  @override
  Future<void> close() async {
    _closed = true;
    _bytes = Uint8List(0);
  }
}
