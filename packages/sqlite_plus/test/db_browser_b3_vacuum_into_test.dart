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

  test('VACUUM INTO stays short of the pinned file', () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    final dir = await Directory.systemTemp.createTemp('sqlite-plus-vacuum-');
    addTearDown(() => dir.delete(recursive: true));
    final out = '${dir.path}/out.db';
    final script = "CREATE TABLE t(v); INSERT INTO t VALUES (1),(3); "
        "VACUUM INTO '$out'; SELECT v FROM t;";
    final created = await Process.run(tool, [':memory:', script]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    expect(created.stdout.toString().trim(), '1\n3');
    final check = await Process.run(
        tool, [out, 'PRAGMA integrity_check; SELECT v FROM t;']);
    expect(check.exitCode, 0, reason: check.stderr.toString());
    expect(check.stdout.toString().trim(), 'ok\n1\n3');
    final again = await Process.run(tool, [':memory:', "VACUUM INTO '$out';"]);
    expect(again.exitCode, isNonZero);
    expect(again.stderr.toString(), contains('output file already exists'));
    final txn = await Process.run(tool, [
      ':memory:',
      "BEGIN; CREATE TABLE t(v); VACUUM INTO '${dir.path}/x.db';"
    ]);
    expect(txn.exitCode, isNonZero);
    expect(txn.stderr.toString(),
        contains('cannot VACUUM from within a transaction'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1),(3)');
    final dest = '${dir.path}/engine.db';
    SqlException? error;
    try {
      await db.execute("VACUUM INTO '$dest'");
    } on SqlException catch (caught) {
      error = caught;
    }
    expect(error, isNotNull);
    expect(error!.message, 'Unknown database: into');
    expect(File(dest).existsSync(), isFalse);
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
    final named = '${dir.path}/main.db';
    final mainInto = await Process.run(tool, [
      ':memory:',
      "CREATE TABLE t(v); INSERT INTO t VALUES (4); VACUUM main INTO '$named';"
    ]);
    expect(mainInto.exitCode, 0, reason: mainInto.stderr.toString());
    final namedRows = await Process.run(tool, [named, 'SELECT v FROM t;']);
    expect(namedRows.stdout.toString().trim(), '4');
    SqlException? namedError;
    try {
      await db.execute("VACUUM main INTO '$named'");
    } on SqlException catch (caught) {
      namedError = caught;
    }
    expect(namedError, isNotNull);
    expect(namedError!.message, 'Unsupported or trailing SQL');
    await db.execute('VACUUM');
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
  });
}
