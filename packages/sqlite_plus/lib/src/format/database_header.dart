import 'dart:typed_data';

/// The 100-byte SQLite 3 database header. Does not open a database or read WAL.
final class DatabaseHeader {
  DatabaseHeader._(this._words, this.pageSize, this.writeVersion,
      this.readVersion, this.reservedBytes);

  final List<int> _words;
  final int pageSize;
  final int writeVersion;
  final int readVersion;
  final int reservedBytes;
  int get usableSize => pageSize - reservedBytes;
  int get changeCounter => _words[0];
  int get databaseSize => _words[1];
  int get firstFreelistTrunk => _words[2];
  int get freelistPages => _words[3];
  int get schemaCookie => _words[4];
  int get schemaFormat => _words[5];
  int get defaultCacheSize => _words[6].toSigned(32);
  int get largestRootPage => _words[7];
  int get textEncoding => _words[8];
  int get userVersion => _words[9];
  int get incrementalVacuum => _words[10];
  int get applicationId => _words[11];
  int get versionValidFor => _words[17];
  int get sqliteVersion => _words[18];

  /// A stale size field must not override the physical file size.
  bool get hasValidDatabaseSize =>
      databaseSize != 0 && changeCounter == versionValidFor;

  factory DatabaseHeader.decode(Uint8List bytes) {
    if (bytes.length < 100) throw const FormatException('Truncated header');
    const magic = [
      83,
      81,
      76,
      105,
      116,
      101,
      32,
      102,
      111,
      114,
      109,
      97,
      116,
      32,
      51,
      0
    ];
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const FormatException('Invalid signature');
      }
    }
    final data = ByteData.sublistView(bytes);
    final encodedSize = data.getUint16(16);
    final size = encodedSize == 1 ? 65536 : encodedSize;
    if (size < 512 || size > 65536 || (size & (size - 1)) != 0) {
      throw const FormatException('Invalid page size');
    }
    if (![1, 2].contains(bytes[18]) || ![1, 2].contains(bytes[19])) {
      throw const FormatException('Unsupported read/write format');
    }
    if (size - bytes[20] < 480) {
      throw const FormatException('Insufficient usable page size');
    }
    if (bytes[21] != 64 || bytes[22] != 32 || bytes[23] != 32) {
      throw const FormatException('Invalid payload fractions');
    }
    final words = List<int>.generate(19, (i) => data.getUint32(24 + i * 4));
    if (words[5] > 4 || words[8] > 3) {
      throw const FormatException(
          'Unsupported schema, encoding or vacuum mode');
    }
    if (words[10] != 0 && words[7] == 0) {
      throw const FormatException('Incremental vacuum requires auto vacuum');
    }
    for (var i = 72; i < 92; i++) {
      if (bytes[i] != 0) throw const FormatException('Nonzero reserved header');
    }
    return DatabaseHeader._(words, size, bytes[18], bytes[19], bytes[20]);
  }

  /// Validates physical framing of a main database file, not WAL consistency.
  int validateFileLength(int length) {
    if (length < pageSize || length % pageSize != 0) {
      throw const FormatException('Truncated or unaligned database');
    }
    final count = length ~/ pageSize;
    if (hasValidDatabaseSize && databaseSize > count) {
      throw const FormatException('Database size exceeds file');
    }
    return count;
  }
}
