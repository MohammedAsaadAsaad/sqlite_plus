import 'dart:typed_data';

import '../format/database_header.dart';
import '../storage/storage_backend.dart';

/// Read-only pages of one database image.
///
/// A non-vacuum rollback image is read as stored. An auto-vacuum image is
/// read through its B-tree pointers; pointer-map pages are not B-tree pages.
/// Write version 2 is the checkpointed or already recovered WAL image.
/// Sidecar recovery and the SQLite lock protocol belong to the file open.
/// Owns the backend after a successful open; failed opens leave it to the caller.
final class ReadOnlyPager {
  ReadOnlyPager._(this._storage, this.header, this.pageCount);
  final StorageBackend _storage;
  final DatabaseHeader header;
  final int pageCount;
  int pagesRead = 0;
  bool _closed = false;

  static Future<ReadOnlyPager> open(StorageBackend storage) async {
    final bytes = await _readExact(storage, 0, 100);
    final header = DatabaseHeader.decode(bytes);
    if (header.readVersion != header.writeVersion) {
      throw UnsupportedError('Mismatched read and write versions');
    }
    final physicalPages = header.validateFileLength(await storage.length());
    final pages =
        header.hasValidDatabaseSize ? header.databaseSize : physicalPages;
    return ReadOnlyPager._(storage, header, pages);
  }

  Future<Uint8List> readPage(int pageNumber) async {
    if (_closed) throw StateError('Pager is closed');
    pagesRead++;
    if (pageNumber < 1 || pageNumber > pageCount) {
      throw const FormatException('Page reference outside database');
    }
    return _readExact(
        _storage, (pageNumber - 1) * header.pageSize, header.pageSize);
  }

  static Future<Uint8List> _readExact(
      StorageBackend storage, int offset, int size) async {
    final result = Uint8List(size);
    var read = 0;
    while (read < size) {
      final remaining = Uint8List.sublistView(result, read);
      final count = await storage.read(offset + read, remaining);
      if (count <= 0 || count > remaining.length) {
        throw const FormatException('Truncated database read');
      }
      read += count;
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _storage.close();
  }
}
