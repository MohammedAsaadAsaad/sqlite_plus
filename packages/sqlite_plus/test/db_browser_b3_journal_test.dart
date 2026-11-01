import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus/src/format/hot_journal.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  if (!File(cli()).existsSync()) {
    test('pinned sqlite3 is not installed', () {
      markTestSkipped('pinned sqlite3 is not installed');
    });
    return;
  }

  test('journal_mode matches the pinned memory and file results', () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    for (final sql in [
      'PRAGMA journal_mode',
      'PRAGMA journal_mode=memory',
      'PRAGMA journal_mode=MEMORY',
      'PRAGMA journal_mode=off',
      'PRAGMA journal_mode=delete',
      'PRAGMA journal_mode=wal',
      'PRAGMA journal_mode=persist',
      'PRAGMA journal_mode=truncate',
      'PRAGMA journal_mode=rollback',
      'PRAGMA journal_mode=nope',
    ]) {
      final result = await Process.run(tool, [':memory:', sql]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
      expect(result.stdout.toString().trim(), 'memory', reason: sql);
      expect(
          (await db.query(sql)).rows,
          [
            ['memory']
          ],
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    expect(before[18], 1);
    expect(sqlJournalMode(before[18]), 'rollback');
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1)');
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('PRAGMA journal_mode')).rows, [
      ['memory']
    ]);

    final directory =
        await Directory.systemTemp.createTemp('sqlite-plus-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final pinFile = '${directory.path}/pin.db';
    final script = await Process.run(tool, [
      pinFile,
      'PRAGMA journal_mode; '
          'PRAGMA journal_mode=off; '
          'CREATE TABLE t(v); INSERT INTO t VALUES (1); '
          'PRAGMA journal_mode=memory; '
          'PRAGMA journal_mode; '
          'SELECT v FROM t;'
    ]);
    expect(script.exitCode, 0, reason: script.stderr.toString());
    expect(
        script.stdout.toString().trim(), 'delete\ndelete\nmemory\nmemory\n1');
    final pinBytes = await File(pinFile).readAsBytes();
    expect(pinBytes[18], 1);
    expect(pinBytes[19], 1);

    final seed = await MutableSqliteDatabase.create();
    final image = seed.exportImage();
    await seed.close();
    final path = '${directory.path}/engine.db';
    final log = '${directory.path}/engine.db-journal';
    await File(path).writeAsBytes(image);
    await File(log).writeAsBytes(const <int>[]);
    final database = await DurableFileStorageBackend.openExisting(path,
        directoryEntryIsDurable: true);
    final journal = await DurableFileStorageBackend.openExisting(log,
        directoryEntryIsDurable: true);
    final pager = await RollbackJournalPager.open(database, journal);
    final fileDb = await MutableSqliteDatabase.fromJournalPager(pager);
    addTearDown(fileDb.close);
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['delete']
    ]);
    expect((await fileDb.query('PRAGMA journal_mode=off')).rows, [
      ['delete']
    ]);
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['delete']
    ]);
    await fileDb.execute('CREATE TABLE t(v)');
    await fileDb.execute('INSERT INTO t VALUES (1)');
    expect((await fileDb.query('PRAGMA journal_mode=memory')).rows, [
      ['memory']
    ]);
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['memory']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    final stored = await File(path).readAsBytes();
    expect(stored[18], 1);
    expect(stored[19], 1);
    expect((await fileDb.query('PRAGMA journal_mode=delete')).rows, [
      ['delete']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    await fileDb.execute('BEGIN');
    await expectLater(
        fileDb.execute('PRAGMA journal_mode=wal'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cannot change into wal mode from within a transaction')));
    await fileDb.execute('COMMIT');

    final beforeWal = fileDb.exportImage();
    expect((await fileDb.query('PRAGMA journal_mode=wal')).rows, [
      ['wal']
    ]);
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['wal']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    final walBytes = await File(path).readAsBytes();
    expect(walBytes[18], 2);
    expect(walBytes[19], 2);
    expect(ByteData.sublistView(walBytes).getUint32(24),
        ByteData.sublistView(beforeWal).getUint32(24) + 1);
    expect(ByteData.sublistView(walBytes).getUint32(92),
        ByteData.sublistView(walBytes).getUint32(24));
    expect(File('$path-wal').existsSync(), isFalse);
    final walCopy = '${directory.path}/wal-copy.db';
    await File(walCopy).writeAsBytes(walBytes);
    final walPin = await Process.run(tool, [
      walCopy,
      'PRAGMA journal_mode; SELECT v FROM t; PRAGMA integrity_check;'
    ]);
    expect(walPin.exitCode, 0, reason: walPin.stderr.toString());
    expect(walPin.stdout.toString().trim(), 'wal\n1\nok');
    await fileDb.execute('BEGIN');
    await expectLater(
        fileDb.execute('PRAGMA journal_mode=delete'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cannot change out of wal mode from within a transaction')));
    await fileDb.execute('COMMIT');
    expect((await fileDb.query('PRAGMA journal_mode=delete')).rows, [
      ['delete']
    ]);
    expect((await File(path).readAsBytes())[18], 1);
    expect((await File(path).readAsBytes())[19], 1);

    expect((await fileDb.query('PRAGMA journal_mode=persist')).rows, [
      ['persist']
    ]);
    await fileDb.execute('UPDATE t SET v=2');
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['persist']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.two]
    ]);
    final persisted = await File(path).readAsBytes();
    expect(persisted[18], 1);
    expect(persisted[19], 1);
    final persistJournal = await File(log).readAsBytes();
    expect(persistJournal.length, greaterThan(28));
    expect(persistJournal.sublist(0, 28), List<int>.filled(28, 0));
    expect(persistJournal.length % (4096 + 8), 512);
    final persistCopy = '${directory.path}/persist-copy.db';
    await File(persistCopy).writeAsBytes(persisted);
    final persistPin = await Process.run(
        tool, [persistCopy, 'SELECT v FROM t; PRAGMA integrity_check;']);
    expect(persistPin.exitCode, 0, reason: persistPin.stderr.toString());
    expect(persistPin.stdout.toString().trim(), '2\nok');

    expect((await fileDb.query('PRAGMA journal_mode=truncate')).rows, [
      ['truncate']
    ]);
    await fileDb.execute('UPDATE t SET v=3');
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.from(3)]
    ]);
    expect(await File(log).length(), 0);
    final truncated = await File(path).readAsBytes();
    expect(truncated[18], 1);
    final truncateCopy = '${directory.path}/truncate-copy.db';
    await File(truncateCopy).writeAsBytes(truncated);
    final truncatePin = await Process.run(
        tool, [truncateCopy, 'SELECT v FROM t; PRAGMA integrity_check;']);
    expect(truncatePin.exitCode, 0, reason: truncatePin.stderr.toString());
    expect(truncatePin.stdout.toString().trim(), '3\nok');

    expect((await fileDb.query('PRAGMA temp.journal_mode=wal')).rows, [
      ['delete']
    ]);
    expect((await fileDb.query('PRAGMA temp.journal_mode=persist')).rows, [
      ['persist']
    ]);
    expect((await fileDb.query('PRAGMA temp.journal_mode=truncate')).rows, [
      ['truncate']
    ]);
  });

  test('a hot official journal rolls back and an invalidated one does not',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sqlite-plus-hot-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final seed = await MutableSqliteDatabase.create();
    await seed.execute('CREATE TABLE t(v)');
    await seed.execute('INSERT INTO t VALUES (1)');
    final original = seed.exportImage();
    await seed.close();
    final path = '${directory.path}/hot.db';
    final log = '${directory.path}/hot.db-journal';
    final changed = Uint8List.fromList(original);
    final fields = ByteData.sublistView(changed);
    fields.setInt32(60, 7);
    final counter = fields.getUint32(24) + 1;
    fields.setUint32(24, counter);
    fields.setUint32(92, counter);
    final journal = HotJournal.encode(
        pages: [(1, Uint8List.sublistView(original, 0, 4096))],
        originalPages: original.length ~/ 4096,
        sectorSize: 512,
        checksumInit: 0x0a3aa146);
    await File(path).writeAsBytes(changed);
    await File(log).writeAsBytes(journal);
    final rolled = await MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(
            await DurableFileStorageBackend.openExisting(path,
                directoryEntryIsDurable: true),
            await DurableFileStorageBackend.openExisting(log,
                directoryEntryIsDurable: true)));
    addTearDown(rolled.close);
    expect((await rolled.query('PRAGMA user_version')).rows, [
      [BigInt.zero]
    ]);
    expect(await File(log).length(), 0);
    await rolled.close();

    HotJournal.invalidateHeader(journal);
    await File(path).writeAsBytes(changed);
    await File(log).writeAsBytes(journal);
    final kept = await MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(
            await DurableFileStorageBackend.openExisting(path,
                directoryEntryIsDurable: true),
            await DurableFileStorageBackend.openExisting(log,
                directoryEntryIsDurable: true)));
    addTearDown(kept.close);
    expect((await kept.query('PRAGMA user_version')).rows, [
      [BigInt.from(7)]
    ]);
    expect(await File(log).length(), journal.length);
    expect((await File(log).readAsBytes()).sublist(0, 28),
        List<int>.filled(28, 0));
  });
}
