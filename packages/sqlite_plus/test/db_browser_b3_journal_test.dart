import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
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
    await expectLater(
        fileDb.execute('PRAGMA journal_mode=wal'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode wal is not implemented')));
    await expectLater(
        fileDb.execute('PRAGMA journal_mode=persist'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode persist is not implemented')));
    await expectLater(
        fileDb.execute('PRAGMA journal_mode=truncate'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode truncate is not implemented')));
    expect((await fileDb.query('PRAGMA journal_mode')).rows, [
      ['delete']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
    expect((await File(path).readAsBytes())[18], 1);
  });
}
