import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

Object? expectedValue(dynamic value) {
  if (value is Map && value.containsKey('integer')) {
    return BigInt.parse(value['integer'] as String);
  }
  if (value is Map && value.containsKey('blob')) {
    final hex = value['blob'] as String;
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);
  }
  return value;
}

final class ShortReadStorage implements StorageBackend {
  ShortReadStorage(this.bytes, {this.chunk = 7});
  final Uint8List bytes;
  final int chunk;
  bool closed = false;
  int writes = 0;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<int> read(int offset, Uint8List buffer) async {
    if (offset >= bytes.length) return 0;
    final size = min(chunk, min(buffer.length, bytes.length - offset));
    buffer.setRange(0, size, bytes, offset);
    return size;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> sync() async {
    writes++;
  }

  @override
  Future<void> truncate(int size) async {
    writes++;
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    writes++;
  }
}

Uint8List fixture() => File('test/fixtures/sqlite-512.db').readAsBytesSync();

Future<ReadOnlyPager> memoryPager(Uint8List bytes) =>
    ReadOnlyPager.open(ShortReadStorage(bytes, chunk: 65536));

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/records.json').readAsStringSync()) as List;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final item in oracle) {
    test(
        '${item['file']}: all records match pinned SQLite via real file adapter',
        () async {
      final path = 'test/fixtures/${item['file']}';
      final before = File(path).readAsBytesSync();
      final storage = await ReadOnlyFileStorageBackend.open(path);
      final pager = await ReadOnlyPager.open(storage);
      addTearDown(pager.close);
      final reader = BtreeReader(pager);
      for (final tree in item['trees']) {
        final stream = tree['kind'] == 'table'
            ? reader.scanTable(tree['root'] as int)
            : reader.scanIndex(tree['root'] as int);
        final records = await stream.toList();
        final expected = tree['records'] as List;
        expect(records.length, expected.length, reason: tree['name'] as String);
        for (var i = 0; i < records.length; i++) {
          expect(
              records[i].rowId,
              expected[i]['rowid'] == null
                  ? null
                  : BigInt.parse(expected[i]['rowid'] as String));
          expect(records[i].values,
              (expected[i]['values'] as List).map(expectedValue).toList(),
              reason: '${tree['name']} record $i');
        }
      }
      await pager.close();
      expect(File(path).readAsBytesSync(), before);
    });
  }

  test(
      'pager retries partial reads, never writes, returns independent pages, closes',
      () async {
    final storage = ShortReadStorage(fixture());
    final pager = await ReadOnlyPager.open(storage);
    final first = await pager.readPage(1);
    first[0] = 0;
    expect((await pager.readPage(1))[0], 83);
    expect(storage.writes, 0);
    await pager.close();
    await pager.close();
    expect(storage.closed, isTrue);
    await expectLater(pager.readPage(1), throwsStateError);
  });
  test('pager rejects missing, truncated, misaligned, and WAL databases',
      () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List(99),
      fixture().sublist(0, 513)
    ]) {
      await expectLater(memoryPager(bytes), throwsFormatException);
    }
    final bytes = fixture()
      ..[18] = 2
      ..[19] = 2;
    await expectLater(memoryPager(bytes), throwsUnsupportedError);
  });
  test('logical size excludes trailing pages; stale size uses physical pages',
      () async {
    final bytes = fixture();
    final data = ByteData.sublistView(bytes);
    data.setUint32(28, 1);
    final pager = await memoryPager(bytes);
    expect(pager.pageCount, 1);
    await expectLater(pager.readPage(2), throwsFormatException);
    await expectLater(pager.readPage(0), throwsFormatException);
    await pager.close();
    data.setUint32(92, data.getUint32(24) + 1);
    final stale = await memoryPager(bytes);
    expect(stale.pageCount, bytes.length ~/ 512);
    await stale.close();
  });
  test('EOF after successful open fails exact page read', () async {
    // Use a separate mutable backend, never truncate a fixture.
    final memory = MemoryStorageBackend();
    await memory.write(0, fixture());
    final pager = await ReadOnlyPager.open(memory);
    await memory.truncate(100);
    await expectLater(pager.readPage(1), throwsFormatException);
    await pager.close();
  });
  test('file backend serializes concurrent reads and rejects mutations',
      () async {
    final storage =
        await ReadOnlyFileStorageBackend.open('test/fixtures/sqlite-512.db');
    addTearDown(storage.close);
    final a = Uint8List(16);
    final b = Uint8List(16);
    await Future.wait([storage.read(0, a), storage.read(16, b)]);
    expect(a, fixture().sublist(0, 16));
    expect(b, fixture().sublist(16, 32));
    await expectLater(storage.read(-1, a), throwsRangeError);
    await expectLater(storage.write(0, a), throwsUnsupportedError);
    await expectLater(storage.truncate(0), throwsUnsupportedError);
    expect(await storage.read(fixture().length, a), 0);
    await storage.sync();
    await storage.close();
    await expectLater(storage.length(), throwsStateError);
  });

  final metadata = (manifest['fixtures'] as List).first;
  final trees = (oracle.first['trees'] as List);
  int root(String name) =>
      (trees.firstWhere((t) => t['name'] == name)['root']) as int;
  int pageOf(String name, String kind) =>
      ((metadata['pages'] as List).firstWhere(
          (p) => p['name'] == name && p['pagetype'] == kind)['pageno']) as int;

  Future<void> rejectTree(Uint8List bytes, int number,
      {bool index = false}) async {
    final pager = await memoryPager(bytes);
    addTearDown(pager.close);
    final reader = BtreeReader(pager);
    await expectLater(
        (index ? reader.scanIndex(number) : reader.scanTable(number)).toList(),
        throwsFormatException);
  }

  test('invalid roots and mixed tree types fail', () async {
    await rejectTree(fixture(), 0);
    await rejectTree(fixture(), root('sample_value'));
    await rejectTree(fixture(), root('sample'), index: true);
  });
  test('B-tree child cycles, zero and out-of-range children fail', () async {
    for (final child in [0, root('sample'), 0xffffffff]) {
      final bytes = fixture();
      final base = (root('sample') - 1) * 512;
      final data = ByteData.sublistView(bytes);
      final cell = data.getUint16(base + 12);
      data.setUint32(base + cell, child);
      await rejectTree(bytes, root('sample'));
    }
  });
  test(
      'overflow cycles, early termination, invalid pages, and excess tail fail',
      () async {
    final number = pageOf('types', 'overflow');
    for (final next in [0, number, 0xffffffff]) {
      final bytes = fixture();
      ByteData.sublistView(bytes).setUint32((number - 1) * 512, next);
      await rejectTree(bytes, root('types'));
    }
    final bytes = fixture();
    final data = ByteData.sublistView(bytes);
    // Corrupt every terminal overflow link so exact-length checking must fail.
    for (final page in metadata['pages'] as List) {
      if (page['name'] == 'types' && page['pagetype'] == 'overflow') {
        final offset = ((page['pageno'] as int) - 1) * 512;
        if (data.getUint32(offset) == 0) data.setUint32(offset, number);
      }
    }
    await rejectTree(bytes, root('types'));
  });
  test('configured payload limit fails before excessive allocation', () async {
    final pager = await memoryPager(fixture());
    addTearDown(pager.close);
    expect(() => BtreeReader(pager, maxPayloadBytes: 0), throwsRangeError);
    await expectLater(
        BtreeReader(pager, maxPayloadBytes: 10)
            .scanTable(root('types'))
            .toList(),
        throwsFormatException);
  });
  test('overlapping cell bodies fail despite distinct valid pointers',
      () async {
    final bytes = fixture();
    final number = pageOf('sample', 'leaf');
    final start = (number - 1) * 512;
    final data = ByteData.sublistView(bytes);
    final first = data.getUint16(start + 8);
    data.setUint16(start + 10, first + 1);
    await rejectTree(bytes, root('sample'));
  });
  test('corrupted table rowid ordering is rejected', () async {
    final bytes = fixture();
    final start = (pageOf('sample', 'leaf') - 1) * 512;
    final data = ByteData.sublistView(bytes);
    final first = data.getUint16(start + 8);
    final second = data.getUint16(start + 10);
    bytes[start + second + 1] = bytes[start + first + 1];
    await rejectTree(bytes, root('sample'));
  });
  test('empty database schema traversal', () async {
    final bytes = Uint8List.fromList(fixture().sublist(0, 512));
    final data = ByteData.sublistView(bytes);
    data.setUint32(28, 1);
    bytes.fillRange(100, 512, 0);
    bytes[100] = 13;
    data.setUint16(105, 512);
    final pager = await memoryPager(bytes);
    addTearDown(pager.close);
    expect(await BtreeReader(pager).scanTable(1).toList(), isEmpty);
  });
  test('table separator bounds and repeated child pages are rejected',
      () async {
    final bytes = fixture();
    final base = (root('sample') - 1) * 512;
    final data = ByteData.sublistView(bytes);
    final firstCell = data.getUint16(base + 12);
    // The first separator must not be lower than the rowids in its child.
    bytes[base + firstCell + 4] = 0;
    await rejectTree(bytes, root('sample'));
    final shared = fixture();
    final sharedData = ByteData.sublistView(shared);
    sharedData.setUint32(base + 8, sharedData.getUint32(base + firstCell));
    await rejectTree(shared, root('sample'));
  });
  test('cancelled scan does not poison later scans', () async {
    final pager = await memoryPager(fixture());
    addTearDown(pager.close);
    final reader = BtreeReader(pager);
    expect((await reader.scanTable(root('sample')).take(1).toList()).length, 1);
    expect((await reader.scanTable(root('sample')).toList()).length, 200);
  });
  test('reserved tail is excluded from cell decoding', () async {
    final bytes = Uint8List(1024)..setRange(0, 100, fixture());
    final data = ByteData.sublistView(bytes);
    data.setUint32(28, 2);
    bytes[20] = 16;
    bytes[512] = 13;
    data.setUint16(515, 1);
    data.setUint16(517, 492);
    data.setUint16(520, 492);
    bytes.setRange(1004, 1008, [2, 1, 2, 0]);
    bytes.fillRange(1008, 1024, 255);
    final pager = await memoryPager(bytes);
    addTearDown(pager.close);
    final records = await BtreeReader(pager).scanTable(2).toList();
    expect(records.single.rowId, BigInt.one);
    expect(records.single.values, [null]);
    // Advertise a payload that crosses into the reserved region.
    bytes[1004] = 3;
    await expectLater(
        BtreeReader(pager).scanTable(2).toList(), throwsFormatException);
  });
  test('cell varint truncated at page end is rejected', () async {
    final bytes = fixture();
    final base = (pageOf('sample', 'leaf') - 1) * 512;
    final data = ByteData.sublistView(bytes);
    data.setUint16(base + 8, 511);
    bytes[base + 511] = 128;
    await rejectTree(bytes, root('sample'));
  });
  test('deterministic B-tree mutations fail safely or return bounded results',
      () async {
    final random = Random(721);
    for (var i = 0; i < 100; i++) {
      final bytes = fixture();
      final offset = 100 + random.nextInt(bytes.length - 100);
      bytes[offset] ^= 1 << random.nextInt(8);
      final pager = await memoryPager(bytes);
      try {
        final reader = BtreeReader(pager, maxPayloadBytes: 65536);
        await reader.scanTable(root('types')).toList();
        await reader.scanIndex(root('sample_value')).toList();
      } on FormatException {
        // The mutation may affect an unvisited page or remain structurally valid.
      } finally {
        await pager.close();
      }
    }
  });
}
