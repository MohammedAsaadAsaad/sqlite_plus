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

  Future<String> pinnedCli() async {
    final tool = cli();
    expect(File(tool).existsSync(), isTrue);
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  Future<ProcessResult> runCli(String tool, String sql) =>
      Process.run(tool, [':memory:', sql]);

  test('FTS5 porter, trigram, detail, tokendata, and locale stay open',
      () async {
    final tool = await pinnedCli();
    final porter = await runCli(
        tool,
        "PRAGMA auto_vacuum=NONE; "
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter'); "
        "INSERT INTO f VALUES ('running'); "
        "SELECT body FROM f WHERE f MATCH 'run';");
    expect(porter.exitCode, 0, reason: porter.stderr.toString());
    expect(porter.stdout.toString().trim(), 'running');
    final trigram = await runCli(
        tool,
        "PRAGMA auto_vacuum=NONE; "
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram'); "
        "INSERT INTO f VALUES ('abcdef'); "
        "SELECT body FROM f WHERE f MATCH 'bcd';");
    expect(trigram.exitCode, 0, reason: trigram.stderr.toString());
    expect(trigram.stdout.toString().trim(), 'abcdef');
    final missed = await runCli(
        tool,
        "PRAGMA auto_vacuum=NONE; "
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram'); "
        "INSERT INTO f VALUES ('abcdef'); "
        "SELECT count(*) FROM f WHERE f MATCH 'zz';");
    expect(missed.exitCode, 0, reason: missed.stderr.toString());
    expect(missed.stdout.toString().trim(), '0');
    final detail = await runCli(
        tool,
        "PRAGMA auto_vacuum=NONE; "
        "CREATE VIRTUAL TABLE f USING fts5(body, detail=none); "
        "INSERT INTO f VALUES ('hello'); "
        "SELECT body FROM f WHERE f MATCH 'hello';");
    expect(detail.exitCode, 0, reason: detail.stderr.toString());
    expect(detail.stdout.toString().trim(), 'hello');
    for (final sql in [
      "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='unicode61', tokendata=1)",
      'CREATE VIRTUAL TABLE f USING fts5(body, locale=1)',
    ]) {
      final created = await runCli(tool, 'PRAGMA auto_vacuum=NONE; $sql;');
      expect(created.exitCode, 0, reason: '${created.stderr}\n$sql');
      expect(created.stdout.toString().trim(), isEmpty);
    }
    final bad = await runCli(
        tool, "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='nope')");
    expect(bad.exitCode, isNonZero);
    expect(bad.stderr.toString(), contains('no such tokenizer: nope'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await expectLater(
        db.execute(
            "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')"),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'no such tokenizer: porter')));
    await expectLater(
        db.execute(
            "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'no such tokenizer: trigram')));
    await expectLater(
        db.execute('CREATE VIRTUAL TABLE f USING fts5(body, detail=none)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'fts5 option is not implemented: detail')));
    await expectLater(
        db.execute('CREATE VIRTUAL TABLE f USING fts5(body, tokendata=1)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'fts5 option is not implemented: tokendata')));
    await expectLater(
        db.execute('CREATE VIRTUAL TABLE f USING fts5(body, locale=1)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'fts5 option is not implemented: locale')));
    final words = List.filled(2000, 'alpha').join(' ');
    final wide = await runCli(
        tool,
        "PRAGMA auto_vacuum=NONE; "
        "CREATE VIRTUAL TABLE f USING fts5(body); "
        "INSERT INTO f VALUES ('$words'); "
        "SELECT length(body) FROM f WHERE f MATCH 'alpha';");
    expect(wide.exitCode, 0, reason: wide.stderr.toString());
    expect(wide.stdout.toString().trim(), '${words.length}');
    await db.execute('CREATE VIRTUAL TABLE wide USING fts5(body)');
    await db.execute("INSERT INTO wide VALUES ('$words')");
    expect(
        (await db.query(
                "SELECT length(body) FROM wide WHERE wide MATCH 'alpha'"))
            .rows,
        [
          [BigInt.from(words.length)]
        ]);
    await db.execute('CREATE VIRTUAL TABLE u USING fts5(body)');
    await db.execute("INSERT INTO u VALUES ('kept')");
    expect((await db.query("SELECT body FROM u WHERE u MATCH 'kept'")).rows, [
      ['kept']
    ]);
  });
}
