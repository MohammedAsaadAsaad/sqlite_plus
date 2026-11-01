import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('fresh auto_vacuum assignments match the recorded modes', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect((await db.query('PRAGMA auto_vacuum=FULL')).rows, isEmpty);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('PRAGMA auto_vacuum=INCREMENTAL')).rows, isEmpty);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.two]
    ]);
    expect((await db.query('PRAGMA auto_vacuum=NONE')).rows, isEmpty);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.two]
    ]);
    expect((await db.query('PRAGMA auto_vacuum=1')).rows, isEmpty);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.one]
    ]);
    final header = DatabaseHeader.decode(db.exportImage());
    expect(header.largestRootPage, 1);
    expect(header.incrementalVacuum, 0);
    expect(header.databaseSize, 1);
  });

  test('NONE, 3, and a non-numeric name read 0 and stay flexible', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'PRAGMA auto_vacuum=NONE',
      'PRAGMA auto_vacuum=3',
      'PRAGMA auto_vacuum=-1',
      'PRAGMA auto_vacuum=nope',
      "PRAGMA auto_vacuum='none'",
    ]) {
      expect((await db.query(sql)).rows, isEmpty, reason: sql);
      expect(
          (await db.query('PRAGMA auto_vacuum')).rows,
          [
            [BigInt.zero]
          ],
          reason: sql);
    }
    expect((await db.query('PRAGMA auto_vacuum(FULL)')).rows, isEmpty);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('PRAGMA incremental_vacuum')).rows, isEmpty);
    expect((await db.query('PRAGMA incremental_vacuum(1)')).rows, isEmpty);
    expect((await db.query("PRAGMA incremental_vacuum('x')")).rows, isEmpty);
  });

  test('a stored page image cannot turn auto-vacuum on or off', () async {
    final created = await MutableSqliteDatabase.create();
    addTearDown(created.close);
    await created.execute('CREATE TABLE t(v)');
    expect((await created.query('PRAGMA auto_vacuum=FULL')).rows, isEmpty);
    expect((await created.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.zero]
    ]);
    expect(DatabaseHeader.decode(created.exportImage()).largestRootPage, 0);

    final versioned = await MutableSqliteDatabase.create();
    addTearDown(versioned.close);
    await versioned.execute('PRAGMA user_version=3');
    await versioned.execute('PRAGMA auto_vacuum=FULL');
    expect((await versioned.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.zero]
    ]);
    expect((await versioned.query('PRAGMA user_version')).rows, [
      [BigInt.from(3)]
    ]);

    final full = await MutableSqliteDatabase.create();
    addTearDown(full.close);
    await full.execute('PRAGMA auto_vacuum=FULL');
    await full.execute('CREATE TABLE t(v)');
    await full.execute('INSERT INTO t VALUES (1)');
    final image = full.exportImage();
    final opened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(opened.close);
    expect((await opened.query('PRAGMA auto_vacuum=NONE')).rows, isEmpty);
    expect((await opened.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.one]
    ]);
    await opened.execute('PRAGMA auto_vacuum=INCREMENTAL');
    expect((await opened.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.two]
    ]);
    expect(DatabaseHeader.decode(opened.exportImage()).incrementalVacuum, 1);
    expect(DatabaseHeader.decode(opened.exportImage()).largestRootPage,
        greaterThan(0));
    expect((await opened.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
  });

  test('FULL and INCREMENTAL images keep rows and an owned pointer map',
      () async {
    final full = await _populated('FULL');
    addTearDown(full.close);
    expect((await full.query('PRAGMA page_count')).rows, [
      [BigInt.from(3)]
    ]);
    expect((await full.query('PRAGMA freelist_count')).rows, [
      [BigInt.zero]
    ]);
    expect((await full.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect((await full.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    _expectRootPointer(full.exportImage(), 3);

    final incremental = await _populated('INCREMENTAL');
    addTearDown(incremental.close);
    expect((await incremental.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.two]
    ]);
    expect(
        DatabaseHeader.decode(incremental.exportImage()).incrementalVacuum, 1);
    expect((await incremental.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect(
        (await incremental.query('PRAGMA incremental_vacuum')).rows, isEmpty);

    final indexed = await MutableSqliteDatabase.create();
    addTearDown(indexed.close);
    await indexed.execute('PRAGMA auto_vacuum=FULL');
    await indexed.execute('CREATE TABLE t(v)');
    await indexed.execute('CREATE INDEX i ON t(v)');
    await indexed.execute("INSERT INTO t VALUES ('abc')");
    expect((await indexed.query('PRAGMA page_count')).rows, [
      [BigInt.from(4)]
    ]);
    expect((await indexed.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect(indexed.exportImage().sublist(4096, 4106),
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0]);

    await full.execute('DELETE FROM t');
    expect((await full.query('SELECT count(*) FROM t')).rows, [
      [BigInt.zero]
    ]);
    expect((await full.query('PRAGMA freelist_count')).rows, [
      [BigInt.zero]
    ]);
    expect((await full.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('NONE writes do not allocate a pointer map', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1)');
    await db.execute('DELETE FROM t WHERE v=1');
    final image = db.exportImage();
    final header = DatabaseHeader.decode(image);
    expect(header.largestRootPage, 0);
    expect(header.incrementalVacuum, 0);
    expect(header.databaseSize, 2);
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT count(*) FROM t')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('corrupt pointer maps and incremental cookies fail integrity', () async {
    final db = await _populated('FULL');
    addTearDown(db.close);
    final good = db.exportImage();
    final corrupt = Uint8List.fromList(good)..[4096] = 9;
    final opened = await MutableSqliteDatabase.fromImage(corrupt);
    addTearDown(opened.close);
    expect((await opened.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    expect((await opened.query('PRAGMA integrity_check')).rows, [
      ['*** in database main ***\nFailed to read ptrmap key=3']
    ]);
    final fresh = await MutableSqliteDatabase.create();
    final cookie = Uint8List.fromList(fresh.exportImage());
    await fresh.close();
    ByteData.sublistView(cookie).setUint32(64, 1);
    final none = await MutableSqliteDatabase.fromImage(cookie);
    addTearDown(none.close);
    await none.execute('CREATE TABLE t(v)');
    await none.execute('INSERT INTO t VALUES (1)');
    final bad = Uint8List.fromList(none.exportImage());
    ByteData.sublistView(bad).setUint32(64, 1);
    ByteData.sublistView(bad).setUint32(52, 0);
    final readable = await MutableSqliteDatabase.fromImage(bad);
    addTearDown(readable.close);
    expect((await readable.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.zero]
    ]);
    expect((await readable.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    expect((await readable.query('PRAGMA integrity_check')).rows, [
      [
        '*** in database main ***\n'
            'incremental_vacuum enabled with a max rootpage of zero'
      ]
    ]);
  });

  test('a crash while committing an auto-vacuum image recovers', () async {
    final seed = await _populated('FULL');
    final original = seed.exportImage();
    await seed.close();
    final baseline = CrashController();
    final pager = await RollbackJournalPager.open(
        ModelFile(original, baseline), ModelFile(Uint8List(0), baseline));
    final writer = await MutableSqliteDatabase.fromJournalPager(pager);
    await writer.execute('INSERT INTO t VALUES (2)');
    final operations = baseline.operations;
    await writer.close();
    expect(operations, greaterThan(0));
    for (var point = 1; point <= operations; point++) {
      final faults = CrashController()..crashAt = point;
      final database = ModelFile(original, faults);
      final log = ModelFile(Uint8List(0), faults);
      final opened = await RollbackJournalPager.open(database, log);
      final db = await MutableSqliteDatabase.fromJournalPager(opened);
      await expectLater(db.execute('INSERT INTO t VALUES (2)'),
          throwsA(isA<SimulatedCrash>()),
          reason: 'operation $point');
      database.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await RollbackJournalPager.open(database, log);
      final image = await recovered.readImage();
      final reader = await MutableSqliteDatabase.fromImage(image);
      expect(
          (await reader.query('PRAGMA integrity_check')).rows,
          [
            ['ok']
          ],
          reason: 'operation $point');
      expect((await reader.query('PRAGMA auto_vacuum')).rows, [
        [BigInt.one]
      ]);
      final rows = (await reader.query('SELECT v FROM t ORDER BY v')).rows;
      expect(
          rows,
          anyOf(
              equals([
                [BigInt.one]
              ]),
              equals([
                [BigInt.one],
                [BigInt.two]
              ])),
          reason: 'operation $point');
      await reader.close();
      await recovered.close();
    }
  });
}

Future<MutableSqliteDatabase> _populated(String mode) async {
  final db = await MutableSqliteDatabase.create();
  await db.execute('PRAGMA auto_vacuum=$mode');
  await db.execute('CREATE TABLE t(v)');
  await db.execute('INSERT INTO t VALUES (1)');
  return db;
}

void _expectRootPointer(Uint8List image, int page) {
  final header = DatabaseHeader.decode(image);
  final perMap = (header.usableSize ~/ 5) + 1;
  final map = ((page - 2) ~/ perMap) * perMap + 2;
  final offset = (map - 1) * header.pageSize + 5 * (page - map - 1);
  expect(image[offset], 1);
  expect(ByteData.sublistView(image).getUint32(offset + 1), 0);
}

final class SimulatedCrash implements Exception {}

final class CrashController {
  int operations = 0;
  int? crashAt;
  void afterOperation() {
    if (++operations == crashAt) throw SimulatedCrash();
  }
}

final class ModelFile implements DurableStorageBackend {
  ModelFile(Uint8List bytes, this.controller)
      : volatile = Uint8List.fromList(bytes),
        durable = Uint8List.fromList(bytes);
  Uint8List volatile;
  Uint8List durable;
  final CrashController controller;
  void crash() {
    volatile = Uint8List.fromList(durable);
  }

  @override
  Future<int> length() async => volatile.length;
  @override
  Future<int> read(int offset, Uint8List buffer) async {
    if (offset >= volatile.length) return 0;
    final count = min(buffer.length, volatile.length - offset);
    buffer.setRange(0, count, volatile, offset);
    return count;
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    if (offset + bytes.length > volatile.length) {
      final grown = Uint8List(offset + bytes.length)
        ..setRange(0, volatile.length, volatile);
      volatile = grown;
    }
    volatile.setRange(offset, offset + bytes.length, bytes);
    controller.afterOperation();
  }

  @override
  Future<void> truncate(int size) async {
    final next = Uint8List(size);
    next.setRange(0, min(size, volatile.length), volatile);
    volatile = next;
    controller.afterOperation();
  }

  @override
  Future<void> sync() async {
    durable = Uint8List.fromList(volatile);
    controller.afterOperation();
  }

  @override
  Future<void> close() async {}
}
