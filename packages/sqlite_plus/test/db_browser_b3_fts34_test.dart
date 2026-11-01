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

  late String tool;
  setUpAll(() async {
    tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
  });

  Future<String> pinned(List<String> statements) async {
    final result = await Process.run(tool, [':memory:', ...statements]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$statements');
    return result.stdout.toString().trim();
  }

  Future<String> engine(List<String> statements) async {
    final db = await MutableSqliteDatabase.create();
    try {
      String? last;
      for (var i = 0; i < statements.length; i++) {
        final sql = statements[i];
        final query =
            RegExp(r'^\s*(SELECT|PRAGMA|WITH)\b', caseSensitive: false)
                .hasMatch(sql);
        if (query) {
          final rows = await db.query(sql);
          if (i == statements.length - 1) {
            last = rows.rows
                .map((row) => row.map((cell) => cell ?? '').join('|'))
                .join('\n');
          }
        } else {
          await db.execute(sql);
        }
      }
      return last ?? '';
    } finally {
      await db.close();
    }
  }

  test('FTS3 and FTS4 writes match the pinned rows', () async {
    final cases = [
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts3(body)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('')",
        'SELECT count(*) FROM f',
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello')",
        "DELETE FROM f WHERE f MATCH 'hello'",
        'SELECT count(*) FROM f',
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello world')",
        "INSERT INTO f VALUES ('other')",
        "SELECT body FROM f WHERE f MATCH 'missing'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts3(body)',
        "INSERT INTO f VALUES ('Hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4()',
        "INSERT INTO f VALUES ('hello')",
        "SELECT content FROM f WHERE f MATCH 'hello'",
      ],
    ];
    for (final statements in cases) {
      expect(await engine(statements), await pinned(statements),
          reason: statements.join('; '));
    }
  });

  test('negative FTS3 and FTS4 statements match the pin errors', () async {
    final missing = await Process.run(tool, [
      ':memory:',
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      'SELECT body FROM missing',
    ]);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: missing'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE f USING fts4(body)');
    await expectLater(
        db.query('SELECT body FROM missing'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'No such table: missing')));
    await expectLater(db.execute("INSERT INTO missing VALUES ('x')"),
        throwsA(isA<SqlException>()));
    final mismatch = await Process.run(tool, [
      ':memory:',
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      "INSERT INTO f VALUES('a','b')",
    ]);
    expect(mismatch.exitCode, isNonZero);
    expect(mismatch.stderr.toString(),
        contains('table f has 1 columns but 2 values were supplied'));
    await expectLater(db.execute("INSERT INTO f VALUES('a','b')"),
        throwsA(isA<SqlException>()));
  });

  test('boundary empty match and a second row stay distinct', () async {
    final statements = [
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      "INSERT INTO f VALUES ('')",
      "INSERT INTO f VALUES ('hello')",
      "SELECT count(*) FROM f WHERE f MATCH 'hello'",
    ];
    expect(await engine(statements), await pinned(statements));
    final both = [
      'CREATE VIRTUAL TABLE f USING fts3(body)',
      "INSERT INTO f VALUES ('hello')",
      "INSERT INTO f VALUES ('hello world')",
      'SELECT count(*) FROM f',
    ];
    expect(await engine(both), await pinned(both));
  });

  test('regression FTS5 writes and native FTS4 bytes stay put', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE u USING fts5(body)');
    await db.execute("INSERT INTO u VALUES ('kept')");
    expect((await db.query("SELECT body FROM u WHERE u MATCH 'kept'")).rows, [
      ['kept']
    ]);
    final file = File('${Directory.systemTemp.path}/sqlite_plus_fts4_guard.db');
    if (file.existsSync()) file.deleteSync();
    final created = await Process.run(tool, [
      file.path,
      'CREATE VIRTUAL TABLE t USING fts4(title, body)',
      "INSERT INTO t(title, body) VALUES('hello world', 'sqlite')",
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final native =
        await MutableSqliteDatabase.fromImage(await file.readAsBytes());
    addTearDown(native.close);
    expect(
        (await native.query("SELECT title FROM t WHERE t MATCH 'hello'"))
            .rows
            .single
            .single,
        'hello world');
    final before = native.exportImage();
    await expectLater(
        native.execute("INSERT INTO t(title, body) VALUES('more', 'text')"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'FTS3 and FTS4 writes are not implemented')));
    expect(native.exportImage(), before);
  });
}
