import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  Future<String> pinnedCli() async {
    final tool = cli();
    expect(File(tool).existsSync(), isTrue);
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  Future<String> cell(String tool, String sql) async {
    final result = await Process.run(tool, [':memory:', sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    return result.stdout.toString().trim();
  }

  test('FTS3 and FTS4 writes stay rejected beside the pinned rows', () async {
    final tool = await pinnedCli();
    const fts4 = "PRAGMA auto_vacuum=NONE; "
        'CREATE VIRTUAL TABLE f USING fts4(body); '
        "INSERT INTO f VALUES ('hello world'); "
        "SELECT body FROM f WHERE f MATCH 'hello';";
    const fts3 = "PRAGMA auto_vacuum=NONE; "
        'CREATE VIRTUAL TABLE f USING fts3(body); '
        "INSERT INTO f VALUES ('hello'); "
        "SELECT body FROM f WHERE f MATCH 'hello';";
    const empty = "PRAGMA auto_vacuum=NONE; "
        'CREATE VIRTUAL TABLE f USING fts4(body); '
        "INSERT INTO f VALUES (''); "
        'SELECT count(*) FROM f;';
    const deleted = "PRAGMA auto_vacuum=NONE; "
        'CREATE VIRTUAL TABLE f USING fts4(body); '
        "INSERT INTO f VALUES ('hello'); "
        "DELETE FROM f WHERE f MATCH 'hello'; "
        'SELECT count(*) FROM f;';
    expect(await cell(tool, fts4), 'hello world');
    expect(await cell(tool, fts3), 'hello');
    expect(await cell(tool, empty), '1');
    expect(await cell(tool, deleted), '0');
    final missing = await Process.run(tool, [
      ':memory:',
      "CREATE VIRTUAL TABLE f USING fts4(body); SELECT body FROM missing;"
    ]);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: missing'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in const [
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      'CREATE VIRTUAL TABLE g USING fts3(body)',
    ]) {
      await expectLater(
          db.execute(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'FTS3 and FTS4 writes are not implemented')),
          reason: sql);
    }
    await expectLater(
        db.execute("INSERT INTO f VALUES ('')"), throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('DELETE FROM f'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('SELECT count(*) FROM f'), throwsA(isA<SqlException>()));
    await db.execute('CREATE VIRTUAL TABLE u USING fts5(body)');
    await db.execute("INSERT INTO u VALUES ('kept')");
    expect((await db.query("SELECT body FROM u WHERE u MATCH 'kept'")).rows, [
      ['kept']
    ]);
  });
}
