import 'dart:typed_data';

import 'browser_byte_store.dart';
import 'memory_storage_backend.dart';
import 'storage_backend.dart';
import 'storage_capabilities.dart';

/// A byte backend whose image is copied to [store] on sync and close.
///
/// The local buffer behaves like [MemoryStorageBackend]. `durabilityPromised`
/// stays false: a later open can see the last synced image, and power loss is
/// not covered.
final class BrowserStorageBackend implements StorageBackend {
  BrowserStorageBackend._(this._store, this._name, this._local);

  final BrowserByteStore _store;
  final String _name;
  final MemoryStorageBackend _local;
  bool _closed = false;

  static Future<BrowserStorageBackend> open(
      BrowserByteStore store, String name) async {
    final local = MemoryStorageBackend();
    final initial = await store.read(name);
    if (initial != null && initial.isNotEmpty) {
      await local.write(0, initial);
    }
    return BrowserStorageBackend._(store, name, local);
  }

  StorageCapabilities get capabilities => StorageCapabilities.browser;

  void _ensureOpen() {
    if (_closed) throw StateError('Storage is closed');
  }

  Future<void> _push() async {
    final size = await _local.length();
    final bytes = Uint8List(size);
    if (size > 0) {
      final read = await _local.read(0, bytes);
      if (read != size) throw StateError('Short browser image read');
    }
    await _store.write(_name, bytes);
  }

  @override
  Future<int> read(int offset, Uint8List buffer) async {
    _ensureOpen();
    return _local.read(offset, buffer);
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    _ensureOpen();
    await _local.write(offset, bytes);
  }

  @override
  Future<void> truncate(int size) async {
    _ensureOpen();
    await _local.truncate(size);
  }

  @override
  Future<int> length() async {
    _ensureOpen();
    return _local.length();
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
    await _push();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await _push();
    _closed = true;
    await _local.close();
  }
}
