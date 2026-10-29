import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart'
    show ModelFile, CrashController, SimulatedCrash;

void main() {
  Uint8List fixture() => File('test/fixtures/write.db').readAsBytesSync();
  Future<MutableSqliteDatabase> open() =>
      MutableSqliteDatabase.fromImage(fixture());
  test('BEGIN COMMIT and ROLLBACK isolate changes until one durable commit',
      () async {
    final faults = CrashController();
    final file = ModelFile(fixture(), faults);
    final log = ModelFile(Uint8List(0), faults);
    final pager = await RollbackJournalPager.open(file, log);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    addTearDown(db.close);
    await db.execute('BEGIN IMMEDIATE TRANSACTION');
    await db.execute("UPDATE notes SET value='pending' WHERE id=1");
    expect(db.inTransaction, isTrue);
    expect(faults.operations, 0);
    expect((await db.query('SELECT value FROM notes WHERE id=1')).rows, [
      ['pending']
    ]);
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT value FROM notes WHERE id=1')).rows, [
      ['value-1']
    ]);
    expect(faults.operations, 0);
    await db.execute('BEGIN');
    await db.execute('DELETE FROM notes WHERE id>5');
    await db.execute('INSERT INTO notes VALUES(6,?,?)', ['committed', 6]);
    expect(faults.operations, 0);
    await db.execute('END TRANSACTION');
    expect(file.volatile, db.exportImage());
    expect(db.inTransaction, isFalse);
  });
  test('nested named savepoints, duplicate names and rollback-to reuse',
      () async {
    final db = await open();
    addTearDown(db.close);
    await db.execute('BEGIN');
    await db.execute('SAVEPOINT a');
    await db.execute('DELETE FROM notes WHERE id>5');
    await db.execute('SAVEPOINT a');
    await db.execute('DELETE FROM notes');
    await db.execute('ROLLBACK TO a');
    expect((await db.query('SELECT id FROM notes')).rows.length, 5);
    await db.execute('ROLLBACK TO SAVEPOINT a');
    await db.execute('RELEASE a');
    await db.execute('ROLLBACK TO a');
    expect((await db.query('SELECT id FROM notes')).rows.length, 2000);
    await db.execute('RELEASE a');
    expect(db.inTransaction, isTrue);
    await db.execute('COMMIT');
    expect(db.inTransaction, isFalse);
  });
  test('outer savepoint release commits; failed statement keeps transaction',
      () async {
    final db = await open();
    addTearDown(db.close);
    await db.execute('SAVEPOINT "outer"');
    await db.execute('DELETE FROM notes WHERE id>1');
    await expectLater(db.execute("INSERT INTO notes VALUES(1,'duplicate',0)"),
        throwsA(isA<SqlException>()));
    expect(db.inTransaction, isTrue);
    expect((await db.query('SELECT id FROM notes')).rows.length, 1);
    await db.execute('RELEASE SAVEPOINT "outer"');
    expect(db.inTransaction, isFalse);
    expect((await db.query('SELECT id FROM notes')).rows.length, 1);
  });
  test('invalid control statements leave state intact', () async {
    final db = await open();
    addTearDown(db.close);
    for (final sql in [
      'COMMIT',
      'ROLLBACK',
      'RELEASE missing',
      'ROLLBACK TO missing',
      'BEGIN rubbish'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.inTransaction, isFalse);
    }
    await db.execute('BEGIN');
    await expectLater(db.execute('BEGIN'), throwsA(isA<SqlException>()));
    expect(db.inTransaction, isTrue);
    await db.execute('ROLLBACK');
  });
  test('closing a transaction discards unsynced changes', () async {
    final faults = CrashController();
    final file = ModelFile(fixture(), faults);
    final pager =
        await RollbackJournalPager.open(file, ModelFile(Uint8List(0), faults));
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    await db.execute('BEGIN');
    await db.execute('DELETE FROM notes');
    await db.close();
    expect(file.durable, fixture());
    expect(faults.operations, 0);
  });

  test('failed durable COMMIT poisons the session and restart recovers',
      () async {
    final original = fixture();
    final faults = CrashController();
    final file = ModelFile(original, faults);
    final log = ModelFile(Uint8List(0), faults);
    final pager = await RollbackJournalPager.open(file, log);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    await db.execute('BEGIN');
    await db.execute('DELETE FROM notes');
    // The redo write has not been synced, so restart keeps the old image.
    faults.crashAt = 1;
    await expectLater(db.execute('COMMIT'), throwsA(isA<SimulatedCrash>()));
    await expectLater(db.query('SELECT * FROM notes'), throwsStateError);
    file.crash();
    log.crash();
    faults.crashAt = null;
    final recovered = await RollbackJournalPager.open(file, log);
    expect(await recovered.readImage(), original);
    await recovered.close();
    await db.close();
  });
  group('SQLite-generated WAL snapshots', () {
    Uint8List base() => File('test/fixtures/wal-base.db').readAsBytesSync();
    Uint8List wal(String stage) =>
        File('test/fixtures/wal-$stage.log').readAsBytesSync();
    Future<List<List<Object?>>> rows(Uint8List log) async {
      final image = WalSnapshot.rollbackCopy(base(), log);
      final db = await MutableSqliteDatabase.fromImage(image);
      try {
        return (await db
                .query('SELECT id,value FROM notes WHERE id<=2 ORDER BY id'))
            .rows;
      } finally {
        await db.close();
      }
    }

    test('last committed transaction wins', () async {
      expect(await rows(wal('first')), [
        [BigInt.one, 'wal-one'],
        [BigInt.two, 'value-2']
      ]);
      expect(await rows(wal('final')), [
        [BigInt.one, 'wal-one'],
        [BigInt.two, 'wal-two']
      ]);
    });
    test('every truncated tail preserves the preceding commit', () async {
      final first = wal('first');
      final last = wal('final');
      for (var length = first.length; length < last.length; length++) {
        expect(
            await rows(Uint8List.sublistView(last, 0, length)),
            [
              [BigInt.one, 'wal-one'],
              [BigInt.two, 'value-2']
            ],
            reason: 'length $length');
      }
    });
    test('checksum/salt corruption stops before the invalid transaction',
        () async {
      final first = wal('first');
      for (final delta in [0, 8, 12, 16, 20, 24, 100]) {
        final last = wal('final');
        if (first.length + delta >= last.length) continue;
        last[first.length + delta] ^= 1;
        expect(await rows(last), [
          [BigInt.one, 'wal-one'],
          [BigInt.two, 'value-2']
        ]);
      }
    });
    test('invalid headers and resource limits fail', () {
      for (final offset in [0, 4, 8, 16, 24, 28]) {
        final log = wal('final')..[offset] ^= 1;
        expect(() => WalSnapshot.recover(base(), log), throwsFormatException);
      }
      expect(() => WalSnapshot.recover(base(), Uint8List(10)),
          throwsFormatException);
      expect(
          () => WalSnapshot.recover(base(), wal('final'), maxImageBytes: 512),
          throwsFormatException);
      expect(WalSnapshot.recover(base(), Uint8List(0)), base());
    });
  });
  test('exclusive lease rejects duplicate opens within the owning isolate',
      () async {
    final directory = Directory.systemTemp.createTempSync('sqlite-plus-lock-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/data.db';
    File(path).writeAsBytesSync(fixture());
    final first = await DurableFileStorageBackend.openExclusive(path,
        directoryEntryIsDurable: true);
    try {
      await expectLater(
          DurableFileStorageBackend.openExclusive(path,
              directoryEntryIsDurable: true),
          throwsStateError);
    } finally {
      await first.close();
    }
    final second = await DurableFileStorageBackend.openExclusive(path,
        directoryEntryIsDurable: true);
    await second.close();
  });
}
