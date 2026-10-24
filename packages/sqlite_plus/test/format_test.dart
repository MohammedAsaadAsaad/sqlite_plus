import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

Uint8List fixture([int size = 512]) =>
    File('test/fixtures/sqlite-$size.db').readAsBytesSync();

void main() {
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  group('SQLite oracle fixtures', () {
    for (final item in manifest['fixtures'] as List<dynamic>) {
      final size = item['page_size'] as int;
      test('$size byte pages match SQLite dbstat', () {
        final bytes = fixture(size);
        final header = DatabaseHeader.decode(bytes);
        expect(header.pageSize, size);
        expect(header.usableSize, size);
        expect(header.writeVersion, 1);
        expect(header.readVersion, 1);
        expect(header.reservedBytes, 0);
        expect(header.hasValidDatabaseSize, isTrue);
        expect(header.validateFileLength(bytes.length), header.databaseSize);
        expect(header.schemaFormat, 4);
        expect(header.textEncoding, size == 512 ? 1 : (size == 4096 ? 2 : 3));
        expect(header.userVersion, 42);
        expect(header.applicationId, 1397836884);
        expect(header.sqliteVersion, 3053001);
        expect(header.firstFreelistTrunk, 0);
        expect(header.freelistPages, 0);
        expect(header.largestRootPage, 0);
        expect(header.incrementalVacuum, 0);
        expect(header.schemaCookie, greaterThan(0));
        expect(header.defaultCacheSize, 0);
        for (final page in item['pages'] as List<dynamic>) {
          if (page['pagetype'] == 'overflow') continue;
          final number = page['pageno'] as int;
          final decoded = BtreePageHeader.decode(
              Uint8List.sublistView(bytes, (number - 1) * size, number * size),
              database: header,
              pageNumber: number);
          expect(decoded.cellCount, page['ncell']);
          expect(decoded.isLeaf, page['pagetype'] == 'leaf');
          expect(
              decoded.isTable,
              !['sample_value', 'types_blob', 'boundary_blob', 'keyed']
                  .contains(page['name']));
          expect(
              decoded.rightmostChild, decoded.isLeaf ? isNull : greaterThan(0));
        }
      });
    }
  });

  test('all truncated headers fail with FormatException', () {
    for (var length = 0; length < 100; length++) {
      expect(() => DatabaseHeader.decode(Uint8List(length)),
          throwsFormatException);
    }
  });
  test('header corruption and unsupported formats', () {
    for (final edit in <List<int>>[
      [0, 0],
      [15, 1],
      [16, 0],
      [18, 0],
      [19, 3],
      [20, 33],
      [21, 63],
      [22, 31],
      [23, 31],
      [47, 5],
      [59, 4],
      [67, 2],
      [72, 1],
      [91, 1],
    ]) {
      final bytes = fixture();
      bytes[edit[0]] = edit[1];
      expect(() => DatabaseHeader.decode(bytes), throwsFormatException,
          reason: 'offset ${edit[0]}');
    }
  });
  test('all legal page sizes and usable-size boundary', () {
    for (var size = 512; size <= 65536; size *= 2) {
      final bytes = fixture();
      ByteData.sublistView(bytes).setUint16(16, size == 65536 ? 1 : size);
      expect(DatabaseHeader.decode(bytes).pageSize, size);
    }
    final bytes = fixture()..[20] = 32;
    expect(DatabaseHeader.decode(bytes).usableSize, 480);
    for (final size in [0, 2, 511, 513, 32769, 65535]) {
      ByteData.sublistView(bytes).setUint16(16, size);
      expect(() => DatabaseHeader.decode(bytes), throwsFormatException);
    }
  });
  test('unsigned big-endian fields, buffer views, independent decoded state',
      () {
    final bytes = fixture();
    ByteData.sublistView(bytes).setUint32(60, 0xfedcba98);
    ByteData.sublistView(bytes).setInt32(48, -2000);
    final backing = Uint8List(bytes.length + 7)
      ..setRange(7, bytes.length + 7, bytes);
    final header = DatabaseHeader.decode(Uint8List.sublistView(backing, 7));
    bytes[60] = 0;
    expect(header.userVersion, 0xfedcba98);
    expect(header.defaultCacheSize, -2000);
  });
  test('file framing and stale size semantics', () {
    final bytes = fixture();
    final header = DatabaseHeader.decode(bytes);
    for (final size in [0, 100, bytes.length - 1, bytes.length - 512]) {
      expect(() => header.validateFileLength(size), throwsFormatException);
    }
    bytes[95] ^= 1;
    final stale = DatabaseHeader.decode(bytes);
    expect(stale.hasValidDatabaseSize, isFalse);
    expect(stale.validateFileLength(512), 1);
    ByteData.sublistView(bytes).setUint32(28, 0);
    expect(DatabaseHeader.decode(bytes).hasValidDatabaseSize, isFalse);
  });

  Uint8List emptyPage(int type, {int size = 512}) {
    final page = Uint8List(size)..[0] = type;
    ByteData.sublistView(page).setUint16(5, size == 65536 ? 0 : size);
    if (type == 2 || type == 5) ByteData.sublistView(page).setUint32(8, 2);
    return page;
  }

  test('four page types and 65536 content sentinel', () {
    for (final size in [512, 65536]) {
      final header = DatabaseHeader.decode(fixture(size));
      for (final type in [2, 5, 10, 13]) {
        final raw = emptyPage(type, size: size);
        final interior = type == 2 || type == 5;
        // Only page one may represent an interior with zero keys.
        final page =
            interior ? (Uint8List(size)..setRange(100, 112, raw)) : raw;
        final result = BtreePageHeader.decode(page,
            database: header, pageNumber: interior ? 1 : 2);
        expect(result.type, type);
        expect(result.cellContentOffset, size);
        expect(result.cellOffsets, isEmpty);
      }
    }
  });
  test('invalid page framing, pointer bounds, fragments and child', () {
    final header = DatabaseHeader.decode(fixture());
    void reject(Uint8List page) => expect(
        () => BtreePageHeader.decode(page, database: header, pageNumber: 2),
        throwsFormatException);
    reject(Uint8List(511));
    reject(emptyPage(0));
    reject(emptyPage(13)..[7] = 61);
    reject(emptyPage(5)..[11] = 0);
    reject(emptyPage(13)
      ..[5] = 0
      ..[6] = 0);
    reject(emptyPage(13)..[3] = 1);
    final page = emptyPage(13);
    final data = ByteData.sublistView(page);
    data.setUint16(3, 2);
    data.setUint16(5, 500);
    data.setUint16(8, 500);
    data.setUint16(10, 500);
    reject(page);
    data.setUint16(10, 512);
    reject(page);
    data.setUint16(10, 499);
    reject(page);
    expect(() => BtreePageHeader.decode(page, database: header, pageNumber: 0),
        throwsRangeError);
  });
  test('freeblock boundaries, cycles, overlaps and cell collision', () {
    final header = DatabaseHeader.decode(fixture());
    final page = emptyPage(13);
    final data = ByteData.sublistView(page);
    data.setUint16(5, 480);
    data.setUint16(1, 480);
    data.setUint16(482, 4);
    BtreePageHeader decode() =>
        BtreePageHeader.decode(page, database: header, pageNumber: 2);
    expect(decode().firstFreeblock, 480);
    data.setUint16(480, 480);
    expect(decode, throwsFormatException);
    data.setUint16(480, 0);
    for (final size in [0, 3, 33]) {
      data.setUint16(482, size);
      expect(decode, throwsFormatException);
    }
    data.setUint16(482, 4);
    data.setUint16(3, 1);
    data.setUint16(8, 481);
    expect(decode, throwsFormatException);
    data.setUint16(3, 0);
    data.setUint16(1, 510);
    expect(decode, throwsFormatException);
  });
  test('WAL versions and uninitialized schema fields are representable', () {
    final bytes = fixture()
      ..[18] = 2
      ..[19] = 2;
    final data = ByteData.sublistView(bytes);
    data.setUint32(44, 0);
    data.setUint32(56, 0);
    data.setUint32(52, 3);
    data.setUint32(64, 99);
    final header = DatabaseHeader.decode(bytes);
    expect(header.writeVersion, 2);
    expect(header.readVersion, 2);
    expect(header.schemaFormat, 0);
    expect(header.textEncoding, 0);
    expect(header.incrementalVacuum, 99);
  });
  test('reserved tail cannot contain cell content or freeblocks', () {
    final bytes = fixture()..[20] = 16;
    final header = DatabaseHeader.decode(bytes);
    final page = emptyPage(13);
    expect(() => BtreePageHeader.decode(page, database: header, pageNumber: 2),
        throwsFormatException);
    ByteData.sublistView(page).setUint16(5, 496);
    expect(
        BtreePageHeader.decode(page, database: header, pageNumber: 2)
            .cellContentOffset,
        496);
  });
  test('valid multi-freeblock chain and immutable cell offsets', () {
    final header = DatabaseHeader.decode(fixture());
    final page = emptyPage(13);
    final data = ByteData.sublistView(page);
    data.setUint16(5, 480);
    data.setUint16(1, 480);
    data.setUint16(480, 490);
    data.setUint16(482, 4);
    data.setUint16(492, 4);
    final decoded =
        BtreePageHeader.decode(page, database: header, pageNumber: 2);
    expect(decoded.firstFreeblock, 480);
    expect(() => decoded.cellOffsets.add(500), throwsUnsupportedError);
    data.setUint16(480, 486);
    expect(() => BtreePageHeader.decode(page, database: header, pageNumber: 2),
        throwsFormatException);
  });
  test('page one has its B-tree header at offset 100', () {
    final bytes = fixture();
    final header = DatabaseHeader.decode(bytes);
    final page = Uint8List.sublistView(bytes, 0, 512);
    page[100] = 0;
    expect(() => BtreePageHeader.decode(page, database: header, pageNumber: 1),
        throwsFormatException);
  });
}
