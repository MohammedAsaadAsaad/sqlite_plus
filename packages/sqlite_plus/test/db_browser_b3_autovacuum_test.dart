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

  test('auto_vacuum writes stay rejected beside the pinned read', () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    final full =
        await Process.run(tool, [':memory:', 'PRAGMA auto_vacuum=FULL;']);
    expect(full.exitCode, 0, reason: full.stderr.toString());
    expect(full.stdout.toString(), isEmpty);
    final followed = await Process.run(
        tool, [':memory:', 'PRAGMA auto_vacuum=FULL; PRAGMA auto_vacuum;']);
    expect(followed.exitCode, 0, reason: followed.stderr.toString());
    expect(followed.stdout.toString().trim(), '1');
    final incremental = await Process.run(tool, [
      ':memory:',
      'PRAGMA auto_vacuum=INCREMENTAL; PRAGMA auto_vacuum; PRAGMA incremental_vacuum;'
    ]);
    expect(incremental.exitCode, 0, reason: incremental.stderr.toString());
    expect(incremental.stdout.toString().trim(), '2');
    final none = await Process.run(
        tool, [':memory:', 'PRAGMA auto_vacuum=NONE; PRAGMA auto_vacuum;']);
    expect(none.stdout.toString().trim(), '0');
    final invalid = await Process.run(
        tool, [':memory:', 'PRAGMA auto_vacuum=3; PRAGMA auto_vacuum;']);
    expect(invalid.exitCode, 0, reason: invalid.stderr.toString());
    expect(invalid.stdout.toString().trim(), '0');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'PRAGMA auto_vacuum=FULL',
      'PRAGMA auto_vacuum=INCREMENTAL',
      'PRAGMA auto_vacuum=NONE',
      'PRAGMA auto_vacuum=3',
    ]) {
      await expectLater(
          db.execute(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'auto_vacuum is not implemented')),
          reason: sql);
    }
    expect((await db.query('PRAGMA auto_vacuum')).rows, [
      [BigInt.zero]
    ]);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1)');
    await db.execute('DELETE FROM t');
    expect((await db.query('SELECT count(*) FROM t')).rows, [
      [BigInt.zero]
    ]);
  });
}
