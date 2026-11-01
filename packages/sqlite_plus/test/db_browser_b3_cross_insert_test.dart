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

  test('a cross-database insert stays rejected beside the pinned commit',
      () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    const script = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u SELECT v FROM t; "
        "SELECT count(*) FROM aux.u; SELECT v FROM aux.u; SELECT v FROM t;";
    final pinned = await Process.run(tool, [':memory:', script]);
    expect(pinned.exitCode, 0, reason: pinned.stderr.toString());
    expect(pinned.stdout.toString().trim(), '1\nm\nm');
    final missing = await Process.run(tool, [
      ':memory:',
      "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
          "INSERT INTO aux.u SELECT v FROM t;"
    ]);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: aux.u'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute("INSERT INTO t VALUES ('m')");
    await db.execute("ATTACH ':memory:' AS aux");
    await db.execute('CREATE TABLE aux.u(v)');
    await expectLater(
        db.execute('INSERT INTO aux.u SELECT v FROM t'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cross-database statement is not supported')));
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    await db.execute("INSERT INTO t VALUES ('n')");
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows, [
      ['m'],
      ['n']
    ]);
    expect((await db.query('SELECT main.t.v, aux.u.v FROM main.t, aux.u')).rows,
        isEmpty);
  });
}
