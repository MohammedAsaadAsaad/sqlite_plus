import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
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

  test('journal_mode stays off the pinned memory and file results', () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    for (final sql in [
      'PRAGMA journal_mode',
      'PRAGMA journal_mode=memory',
      'PRAGMA journal_mode=MEMORY',
      'PRAGMA journal_mode=off',
      'PRAGMA journal_mode=delete',
      'PRAGMA journal_mode=wal',
    ]) {
      final result = await Process.run(tool, [':memory:', sql]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
      expect(result.stdout.toString().trim(), 'memory', reason: sql);
    }
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect((await db.query('PRAGMA journal_mode')).rows, [
      ['rollback']
    ]);
    await expectLater(
        db.execute('PRAGMA journal_mode=memory'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode memory is not implemented')));
    await expectLater(
        db.execute('PRAGMA journal_mode=off'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode off is not implemented')));
    await expectLater(
        db.execute('PRAGMA journal_mode=delete'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'journal_mode delete is not implemented')));
    expect((await db.query('PRAGMA journal_mode')).rows, [
      ['rollback']
    ]);
    final file = '${Directory.systemTemp.path}/sqlite-plus-journal-$pid.db';
    addTearDown(() {
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final path = File('$file$suffix');
        if (path.existsSync()) path.deleteSync();
      }
    });
    final script = await Process.run(tool, [
      file,
      'PRAGMA journal_mode; '
          'PRAGMA journal_mode=off; '
          'CREATE TABLE t(v); INSERT INTO t VALUES (1); '
          'PRAGMA journal_mode=memory; '
          "SELECT v FROM t;"
    ]);
    expect(script.exitCode, 0, reason: script.stderr.toString());
    expect(script.stdout.toString().trim(), 'delete\ndelete\nmemory\n1');
    await db.execute('PRAGMA journal_mode=rollback');
    expect((await db.query('PRAGMA journal_mode')).rows, [
      ['rollback']
    ]);
  });
}
