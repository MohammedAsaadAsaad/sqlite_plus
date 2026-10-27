import 'dart:typed_data';

import '../format/database_header.dart';
import '../storage/storage_backend.dart';

/// Read-only view of a stable, journal-free, rollback-format database copy.
/// No locking, recovery, WAL reconciliation, or concurrent-writer protection.
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
    if (header.largestRootPage != 0) {
      throw UnsupportedError('auto_vacuum databases are not supported');
    }
    if (header.readVersion != 1 || header.writeVersion != 1) {
      throw UnsupportedError(
          'WAL databases require checkpointing to rollback format');
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
