import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  Future<String?> pinnedCli() async {
    final tool = cli();
    if (!File(tool).existsSync()) return null;
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  test('double quotes stay identifiers while the mode is off', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect(db.doubleQuotedStrings, isFalse);
    await db.execute('CREATE TABLE t(title)');
    await db.execute("INSERT INTO t VALUES('value')");
    expect((await db.query('SELECT "title" FROM t')).rows, [
      ['value']
    ]);
    await expectLater(
        db.query('SELECT "missing"'), throwsA(isA<SqlException>()));
  });

  test('double-quoted strings match the pinned CLI when the mode is on',
      () async {
    final tool = await pinnedCli();
    if (tool == null) fail('pinned sqlite3 is missing');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.doubleQuotedStrings = true;
    const setup = '''
      CREATE TABLE t(title);
      INSERT INTO t VALUES('value');
      CREATE TABLE c(a CHECK (a="ok"));
      INSERT INTO c VALUES('ok')
    ''';
    for (final statement in setup.split(';')) {
      final text = statement.trim();
      if (text.isNotEmpty) await db.execute(text);
    }
    Future<void> match(String sql) async {
      final engine =
          (await db.query(sql)).rows.map((row) => row.join('|')).join('\n');
      final result = await Process.run(tool, [':memory:', setup, sql]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
      expect(engine, result.stdout.toString().trimRight(), reason: sql);
    }

    await match('SELECT "missing"');
    await match('SELECT "MiSsInG"');
    await match('SELECT ""');
    await match('SELECT "a""b"');
    await match('SELECT "hello world"');
    await match('SELECT "from"');
    await match('SELECT "true"');
    await match('SELECT "title" FROM t');
    await match('SELECT "TITLE" FROM t');
    await match('SELECT "missing" FROM t');
    await match('SELECT "a.title" FROM t');
    await match('''SELECT "missing" || 'x' ''');
    await match('SELECT count(*), "missing" FROM t');
    await match('SELECT "title", count(*) FROM t GROUP BY "title"');
    await match("SELECT typeof(\"1\"), \"1\"+1");
    await match('SELECT title FROM t WHERE title="value"');
    await match(
        'SELECT (SELECT "missing"), (SELECT "title" FROM t WHERE title="value")');
    await match('SELECT * FROM c');
    await expectLater(
        db.execute("INSERT INTO c VALUES('no')"), throwsA(isA<SqlException>()));
    final rejected = await Process.run(
        tool, [':memory:', setup, "INSERT INTO c VALUES('no')"]);
    expect(rejected.exitCode, isNot(0));
    expect(rejected.stderr.toString(), contains('CHECK constraint failed'));
    await expectLater(
        db.query('SELECT [missing]'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('SELECT `missing`'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('SELECT t."missing" FROM t'), throwsA(isA<SqlException>()));
    await expectLater(db.execute('INSERT INTO t("nope") VALUES(1)'),
        throwsA(isA<SqlException>()));
    db.doubleQuotedStrings = false;
    await expectLater(
        db.query('SELECT "missing" FROM t'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such column: missing')));
    await expectLater(
        db.query('SELECT "a.title" FROM t'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such column: a.title')));
  });

  test('ambiguous double-quoted names stay errors when the mode is on',
      () async {
    final tool = await pinnedCli();
    if (tool == null) fail('pinned sqlite3 is missing');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.doubleQuotedStrings = true;
    const setup = '''
      CREATE TABLE a(title);
      INSERT INTO a VALUES('left');
      CREATE TABLE b(title);
      INSERT INTO b VALUES('right')
    ''';
    for (final statement in setup.split(';')) {
      final text = statement.trim();
      if (text.isNotEmpty) await db.execute(text);
    }
    await expectLater(
        db.query('SELECT "title" FROM a, b'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'Ambiguous column: title')));
    final cli = await Process.run(
        tool, [':memory:', setup, 'SELECT "title" FROM a, b']);
    expect(cli.exitCode, isNot(0));
    expect(cli.stderr.toString(), contains('ambiguous column name: title'));
    final dotted = await db.query('SELECT "a.title" FROM a, b');
    final dottedCli = await Process.run(
        tool, [':memory:', setup, 'SELECT "a.title" FROM a, b']);
    expect(dottedCli.exitCode, 0, reason: dottedCli.stderr.toString());
    expect(dotted.rows.single.single, 'a.title');
    expect(dotted.rows.single.single.toString(),
        dottedCli.stdout.toString().trimRight());
  });

  test('a double-quoted name matches a column that contains a dot', () async {
    final tool = await pinnedCli();
    if (tool == null) fail('pinned sqlite3 is missing');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.doubleQuotedStrings = true;
    const setup = '''
      CREATE TABLE a(title, "a.title");
      INSERT INTO a VALUES('bare', 'dotted');
      CREATE TABLE only("a.title");
      INSERT INTO only VALUES('solo');
      CREATE TABLE kw("from");
      INSERT INTO kw VALUES('col');
      CREATE TABLE spaced("hello world");
      INSERT INTO spaced VALUES('words')
    ''';
    for (final statement in setup.split(';')) {
      final text = statement.trim();
      if (text.isNotEmpty) await db.execute(text);
    }
    Future<void> match(String sql) async {
      final engine =
          (await db.query(sql)).rows.map((row) => row.join('|')).join('\n');
      final result = await Process.run(tool, [':memory:', setup, sql]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
      expect(engine, result.stdout.toString().trimRight(), reason: sql);
    }

    await match('SELECT "a.title", "title" FROM a');
    // Unquoted a.title still resolves to the column named "a.title".
    // Pinned SQLite returns the title column. That shape stays unmatched.
    final collision = await db.query('SELECT a.title FROM a');
    expect(collision.rows.single.single, 'dotted');
    final collisionCli =
        await Process.run(tool, [':memory:', setup, 'SELECT a.title FROM a']);
    expect(collisionCli.exitCode, 0, reason: collisionCli.stderr.toString());
    expect(collisionCli.stdout.toString().trimRight(), 'bare');
    await match('SELECT "a.title" FROM only');
    await match('SELECT "from" FROM kw');
    await match('SELECT "hello world" FROM spaced');
    await match("SELECT \"a.title\"='a.title' FROM only");
  });
}
