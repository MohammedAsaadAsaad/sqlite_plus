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

  Future<void> expectSame(List<String> statements) async {
    final cliRows = await pinned(statements);
    final engineRows = await engine(statements);
    expect(engineRows, cliRows, reason: statements.join('; '));
  }

  Future<void> expectError(List<String> statements, String message) async {
    final result = await Process.run(tool, [':memory:', ...statements]);
    expect(result.exitCode, isNonZero, reason: statements.join('; '));
    expect(result.stderr.toString(), contains(message),
        reason: statements.join('; '));
    final db = await MutableSqliteDatabase.create();
    try {
      for (var i = 0; i < statements.length; i++) {
        final sql = statements[i];
        final last = i == statements.length - 1;
        final query =
            RegExp(r'^\s*(SELECT|PRAGMA|WITH)\b', caseSensitive: false)
                .hasMatch(sql);
        if (!last) {
          await db.execute(sql);
          continue;
        }
        final pending = query ? db.query(sql) : db.execute(sql);
        await expectLater(
            pending,
            throwsA(isA<SqlException>()
                .having((error) => error.message, 'message', message)));
      }
    } finally {
      await db.close();
    }
  }

  String sized(int n) => 'a${'x' * (n - 4)}ing';

  Future<void> expectLeaves(List<String> statements) async {
    final db = await MutableSqliteDatabase.create();
    for (final sql in statements) {
      await db.execute(sql);
    }
    final written =
        File('${Directory.systemTemp.path}/sqlite_plus_fts5_leaf.db');
    await written.writeAsBytes(db.exportImage());
    await db.close();
    final native =
        File('${Directory.systemTemp.path}/sqlite_plus_fts5_leaf_pin.db');
    if (native.existsSync()) native.deleteSync();
    final created = await Process.run(tool,
        [native.path, 'PRAGMA auto_vacuum=NONE; ${statements.join('; ')}']);
    expect(created.exitCode, 0, reason: '${created.stderr}\n$statements');
    const query = 'SELECT id, quote(block) FROM f_data ORDER BY id;';
    final engineRows = await Process.run(tool, [written.path, query]);
    final pinRows = await Process.run(tool, [native.path, query]);
    expect(engineRows.exitCode, 0, reason: engineRows.stderr.toString());
    expect(pinRows.exitCode, 0, reason: pinRows.stderr.toString());
    expect(engineRows.stdout.toString(), pinRows.stdout.toString(),
        reason: statements.join('; '));
    final check =
        await Process.run(tool, [written.path, 'PRAGMA integrity_check;']);
    expect(check.exitCode, 0, reason: check.stderr.toString());
    expect(check.stdout.toString().trim(), 'ok');
  }

  test('FTS5 porter, trigram, detail, tokendata, and locale match the pin',
      () async {
    final stem = 'a${'x' * 59}';
    final wide = List.filled(2000, 'alpha').join(' ');
    final positive = <List<String>>[
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('running')",
        "SELECT body FROM f WHERE f MATCH 'run'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('Running')",
        "SELECT body FROM f WHERE f MATCH 'run'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('cats')",
        "SELECT body FROM f WHERE f MATCH 'cat'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f(body) VALUES ('running'), ('runner')",
        "SELECT body FROM f WHERE f MATCH 'run'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('caresses')",
        "SELECT body FROM f WHERE f MATCH 'caress'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('relational')",
        "SELECT body FROM f WHERE f MATCH 'relat'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('happy')",
        "SELECT body FROM f WHERE f MATCH 'happi'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('controll')",
        "SELECT body FROM f WHERE f MATCH 'control'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter ascii')",
        "INSERT INTO f VALUES ('running')",
        "SELECT body FROM f WHERE f MATCH 'run'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT body FROM f WHERE f MATCH 'bcd'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'zz'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT body FROM f WHERE f MATCH 'ABC'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('ab cd')",
        "SELECT body FROM f WHERE f MATCH '\"b c\"'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram', detail=none)",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT body FROM f WHERE f MATCH 'bcd'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH 'hello world'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hel*'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=columns)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=full)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH '\"hello world\"'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=column)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'body:hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, tokendata=1)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, locale=1)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='unicode61', tokendata=1)",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, locale=1)',
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body)',
        "INSERT INTO f VALUES ('$wide')",
        "SELECT length(body) FROM f WHERE f MATCH 'alpha'",
      ],
      [
        'CREATE VIRTUAL TABLE u USING fts5(body)',
        "INSERT INTO u VALUES ('kept')",
        "SELECT body FROM u WHERE u MATCH 'kept'",
      ],
    ];
    for (final statements in positive) {
      await expectSame(statements);
    }

    final boundary = <List<String>>[
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('to')",
        "SELECT body FROM f WHERE f MATCH 'to'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('feed')",
        "SELECT body FROM f WHERE f MATCH 'feed'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('runner')",
        "SELECT count(*) FROM f WHERE f MATCH 'run'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('${sized(63)}')",
        "SELECT count(*) FROM f WHERE f MATCH '${'a${'x' * 58}'}'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('${sized(64)}')",
        "SELECT count(*) FROM f WHERE f MATCH '$stem'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('${sized(65)}')",
        "SELECT count(*) FROM f WHERE f MATCH '${sized(65)}'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('${sized(65)}')",
        "SELECT count(*) FROM f WHERE f MATCH '$stem'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'z'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('ab')",
        'SELECT count(*) FROM f',
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abc')",
        "SELECT count(*) FROM f WHERE f MATCH 'ab'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'bde'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'bcd zz'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'zz OR bcd'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'zz yy'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive 1')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT count(*) FROM f WHERE f MATCH 'ABC'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive 1')",
        "INSERT INTO f VALUES ('abcdef')",
        "SELECT body FROM f WHERE f MATCH 'abc'",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive 0')",
        "INSERT INTO f VALUES ('AbCdef')",
        "SELECT body FROM f WHERE f MATCH 'abc'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT count(*) FROM f WHERE f MATCH '\"---\"'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT count(*) FROM f WHERE f MATCH 'hello \"---\"'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT count(*) FROM f WHERE f MATCH 'hello AND \"---\"'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=c)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=FULL)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH '\"hello world\"'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, tokendata=0)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, locale=0)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
    ];
    for (final statements in boundary) {
      await expectSame(statements);
    }

    final negative = <(List<String>, String)>[
      (
        ["CREATE VIRTUAL TABLE f USING fts5(body, tokenize='nope')"],
        'no such tokenizer: nope',
      ),
      (
        ["CREATE VIRTUAL TABLE f USING fts5(body, tokenize='simple')"],
        'no such tokenizer: simple',
      ),
      (
        ["CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter nope')"],
        'error in tokenizer constructor',
      ),
      (
        ["CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter simple')"],
        'error in tokenizer constructor',
      ),
      (
        [
          "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive 2')"
        ],
        'error in tokenizer constructor',
      ),
      (
        [
          "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive 1 remove_diacritics 1')"
        ],
        'error in tokenizer constructor',
      ),
      (
        [
          "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram case_sensitive')"
        ],
        'error in tokenizer constructor',
      ),
      (
        ['CREATE VIRTUAL TABLE f USING fts5(body, detail=nope)'],
        'malformed detail=... directive',
      ),
      (
        ['CREATE VIRTUAL TABLE f USING fts5(body, detail=)'],
        'malformed detail=... directive',
      ),
      (
        ['CREATE VIRTUAL TABLE f USING fts5(body, tokendata=2)'],
        'malformed tokendata=... directive',
      ),
      (
        ['CREATE VIRTUAL TABLE f USING fts5(body, tokendata=)'],
        'malformed tokendata=... directive',
      ),
      (
        ['CREATE VIRTUAL TABLE f USING fts5(body, locale=01)'],
        'malformed locale=... directive',
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
          "INSERT INTO f VALUES ('hello world')",
          "SELECT body FROM f WHERE f MATCH '\"hello world\"'",
        ],
        'fts5: phrase queries are not supported (detail!=full)',
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts5(body, detail=columns)',
          "INSERT INTO f VALUES ('hello world')",
          "SELECT body FROM f WHERE f MATCH '\"hello world\"'",
        ],
        'fts5: phrase queries are not supported (detail!=full)',
      ),
      (
        [
          "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram', detail=none)",
          "INSERT INTO f VALUES ('abcdef')",
          "SELECT body FROM f WHERE f MATCH 'abcd'",
        ],
        'fts5: phrase queries are not supported (detail!=full)',
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
          "INSERT INTO f VALUES ('hello world')",
          "SELECT body FROM f WHERE f MATCH 'NEAR(hello world, 1)'",
        ],
        'fts5: NEAR queries are not supported (detail!=full)',
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
          "INSERT INTO f VALUES ('hello')",
          "SELECT body FROM f WHERE f MATCH 'body:hello'",
        ],
        'fts5: column queries are not supported (detail=none)',
      ),
    ];
    for (final (statements, message) in negative) {
      await expectError(statements, message);
    }

    final leaves = <List<String>>[
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='porter')",
        "INSERT INTO f VALUES ('running')",
      ],
      [
        "CREATE VIRTUAL TABLE f USING fts5(body, tokenize='trigram')",
        "INSERT INTO f VALUES ('abcdef')",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=none)',
        "INSERT INTO f VALUES ('hello')",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, detail=columns)',
        "INSERT INTO f VALUES ('hello')",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, tokendata=1)',
        "INSERT INTO f VALUES ('hello')",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body, locale=1)',
        "INSERT INTO f VALUES ('hello')",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts5(body)',
        "INSERT INTO f VALUES ('$wide')",
      ],
    ];
    for (final statements in leaves) {
      await expectLeaves(statements);
    }
  });
}
