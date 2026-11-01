import 'dart:io';
import 'dart:typed_data';

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

  Future<String> pinned(String sql, {String path = ':memory:'}) async {
    final result = await Process.run(cli(), [path, sql]);
    final err = result.stderr.toString().trim();
    if (result.exitCode != 0) {
      const marker = 'argument: ';
      final index = err.indexOf(marker);
      final detail = index < 0 ? err : err.substring(index + marker.length);
      return 'ERR ${detail.split('\n').first.trim()}';
    }
    return result.stdout.toString().trim();
  }

  Future<String> engine(String sql) async {
    final db = await MutableSqliteDatabase.create();
    try {
      final parts = <String>[];
      for (final statement in _statements(sql)) {
        final parser = statement.trimLeft().toUpperCase();
        if (parser.startsWith('SELECT') || parser.startsWith('PRAGMA')) {
          final rows = await db.query(statement);
          parts.add(rows.rows
              .map((row) => row.map((value) => value ?? '').join('|'))
              .join('\n'));
        } else {
          await db.execute(statement);
        }
      }
      return parts.join('\n');
    } on SqlException catch (error) {
      return 'ERR ${error.message}';
    } finally {
      await db.close();
    }
  }

  test('a structure-dialog rebuild matches integrity_check and cross-opens',
      () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    const rebuild =
        'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, junk INT);'
        'CREATE INDEX t_name ON t(name);'
        "INSERT INTO t VALUES(1,'a',9),(2,'b',8);"
        'CREATE TABLE t_new(id INTEGER PRIMARY KEY, name TEXT);'
        'INSERT INTO t_new(id, name) SELECT id, name FROM t;'
        'DROP TABLE t;'
        'ALTER TABLE t_new RENAME TO t;'
        'CREATE INDEX t_name ON t(name);'
        'PRAGMA integrity_check;'
        'SELECT id, name FROM t ORDER BY id;'
        'SELECT type, name, sql FROM sqlite_schema ORDER BY name;';
    final cliText = await pinned(rebuild);
    final engineText = await engine(rebuild);
    expect(engineText, cliText);

    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final statement in _statements(rebuild)) {
      final parser = statement.trimLeft().toUpperCase();
      if (parser.startsWith('SELECT') || parser.startsWith('PRAGMA')) {
        await db.query(statement);
      } else {
        await db.execute(statement);
      }
    }
    final image = db.exportImage();
    final dir = await Directory.systemTemp.createTemp('sqlite-plus-b4-');
    addTearDown(() => dir.delete(recursive: true));
    final engineFile = File('${dir.path}/engine.db');
    await engineFile.writeAsBytes(image, flush: true);
    final openedByCli = await Process.run(tool, [
      engineFile.path,
      "PRAGMA integrity_check; SELECT id, name FROM t ORDER BY id;"
    ]);
    expect(openedByCli.exitCode, 0, reason: openedByCli.stderr.toString());
    expect(openedByCli.stdout.toString().trim(), 'ok\n1|a\n2|b');

    final cliFile = File('${dir.path}/cli.db');
    final created = await Process.run(
        tool, [cliFile.path, 'PRAGMA auto_vacuum=NONE; $rebuild']);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final fromCli =
        await MutableSqliteDatabase.fromImage(await cliFile.readAsBytes());
    addTearDown(fromCli.close);
    expect((await fromCli.query('PRAGMA integrity_check')).rows.single.single,
        'ok');
    expect((await fromCli.query('SELECT id, name FROM t ORDER BY id')).rows, [
      [BigInt.one, 'a'],
      [BigInt.two, 'b']
    ]);
    await fromCli.execute("INSERT INTO t(name) VALUES('c')");
    final rewritten = fromCli.exportImage();
    final rewrittenFile = File('${dir.path}/rewritten.db');
    await rewrittenFile.writeAsBytes(rewritten, flush: true);
    final roundTrip = await Process.run(tool, [
      rewrittenFile.path,
      "PRAGMA integrity_check; SELECT name FROM t ORDER BY id;"
    ]);
    expect(roundTrip.exitCode, 0, reason: roundTrip.stderr.toString());
    expect(roundTrip.stdout.toString().trim(), 'ok\na\nb\nc');
  });

  test('rename rejects a view or trigger that names a missing table', () async {
    const view = 'CREATE TABLE t(a,b);'
        'CREATE VIEW v AS SELECT a FROM t;'
        'CREATE TABLE t_new(a);'
        'DROP TABLE t;'
        'ALTER TABLE t_new RENAME TO t;';
    const trigger = 'CREATE TABLE t(a,b);'
        'CREATE TABLE u(x);'
        'CREATE TRIGGER tr AFTER INSERT ON u BEGIN SELECT a FROM t; END;'
        'DROP TABLE t;'
        'CREATE TABLE t_new(a);'
        'ALTER TABLE t_new RENAME TO t;';
    expect(await engine(view), await pinned(view));
    expect(await engine(trigger), await pinned(trigger));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a,b)');
    await db.execute('CREATE VIEW v AS SELECT a FROM t');
    await db.execute('CREATE TABLE t_new(a)');
    await db.execute('DROP TABLE t');
    final before = db.exportImage();
    await expectLater(
        db.execute('ALTER TABLE t_new RENAME TO t'),
        throwsA(predicate((error) =>
            error is SqlException &&
            error.message == 'error in view v: no such table: main.t')));
    expect(db.exportImage(), before);
  });

  test('drop column dependencies match the pinned CLI', () async {
    const scripts = <String>[
      "CREATE TABLE t(a,b); CREATE VIEW v AS SELECT b FROM t; ALTER TABLE t DROP COLUMN b;",
      "CREATE TABLE t(a,b); CREATE TABLE log(x); CREATE TRIGGER tr AFTER UPDATE ON t BEGIN INSERT INTO log VALUES(new.b); END; ALTER TABLE t DROP COLUMN b;",
      "CREATE TABLE t(a,b); CREATE TABLE u(x); CREATE TRIGGER tr AFTER INSERT ON u BEGIN INSERT INTO t(a,b) VALUES(1,new.x); END; ALTER TABLE t DROP COLUMN b; SELECT sql FROM sqlite_schema WHERE type='trigger';",
      "CREATE TABLE t(a,b); CREATE TABLE u(x); CREATE TRIGGER tr AFTER INSERT ON u BEGIN UPDATE t SET b=1; END; ALTER TABLE t DROP COLUMN b; SELECT sql FROM sqlite_schema WHERE name='tr';",
      "CREATE TABLE t(a INTEGER PRIMARY KEY, b); ALTER TABLE t DROP COLUMN a;",
      "CREATE TABLE t(a UNIQUE, b); ALTER TABLE t DROP COLUMN a;",
      "CREATE TABLE t(a); ALTER TABLE t DROP COLUMN a;",
      "CREATE TABLE t(a,b); CREATE INDEX i ON t(b); ALTER TABLE t DROP COLUMN b;",
      "CREATE TABLE t(a, b, UNIQUE(b)); ALTER TABLE t DROP COLUMN b;",
      "CREATE TABLE t(a, b, CHECK(a>b)); ALTER TABLE t DROP COLUMN b;",
      "CREATE TABLE t(a, b AS (1)); ALTER TABLE t DROP COLUMN a;",
      "CREATE TABLE t(a, b AS (a+1), c); ALTER TABLE t DROP COLUMN a;",
      "CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(pid REFERENCES p(id), extra); ALTER TABLE c DROP COLUMN pid; SELECT sql FROM sqlite_schema WHERE name='c';",
      "CREATE TABLE p(id INTEGER PRIMARY KEY, extra); CREATE TABLE c(x INT, pid REFERENCES p(extra)); ALTER TABLE p DROP COLUMN extra; SELECT sql FROM sqlite_schema WHERE name IN ('p','c') ORDER BY name;",
      "CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(pid INT, extra, FOREIGN KEY(pid) REFERENCES p(id)); ALTER TABLE c DROP COLUMN pid;",
      "CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); CREATE VIRTUAL TABLE f USING fts5(body); ALTER TABLE t DROP COLUMN b; SELECT a FROM t; INSERT INTO f VALUES('hi'); SELECT count(*) FROM f;",
      "CREATE VIRTUAL TABLE f USING fts5(body); CREATE TABLE t(a); ALTER TABLE t RENAME TO u; SELECT count(*) FROM f;",
    ];
    for (final sql in scripts) {
      expect(await engine(sql), await pinned(sql), reason: sql);
    }
  });

  test('an empty rebuild and a failed rename leave a readable image', () async {
    const empty = 'CREATE TABLE t(a,b);'
        'CREATE TABLE t_new(a);'
        'INSERT INTO t_new(a) SELECT a FROM t;'
        'DROP TABLE t;'
        'ALTER TABLE t_new RENAME TO t;'
        'PRAGMA integrity_check;'
        'SELECT count(*) FROM t;';
    expect(await engine(empty), await pinned(empty));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INTEGER PRIMARY KEY, v)');
    await db.execute("INSERT INTO t VALUES(1,'kept')");
    await db.execute('CREATE INDEX t_v ON t(v)');
    final before = Uint8List.fromList(db.exportImage());
    await expectLater(db.execute('ALTER TABLE t DROP COLUMN a'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['kept']
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
  });
}

List<String> _statements(String sql) {
  final statements = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  var depth = 0;
  var word = '';
  void flushWord() {
    final upper = word.toUpperCase();
    if (upper == 'BEGIN') depth++;
    if (upper == 'END' && depth > 0) depth--;
    word = '';
  }

  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote.isNotEmpty) {
      buffer.write(char);
      if (char == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          buffer.write(sql[i + 1]);
          i++;
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      flushWord();
      quote = char;
      buffer.write(char);
      continue;
    }
    if (RegExp(r'[A-Za-z_]').hasMatch(char)) {
      word += char;
      buffer.write(char);
      continue;
    }
    flushWord();
    if (char == ';' && depth == 0) {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) statements.add(text);
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  flushWord();
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) statements.add(tail);
  return statements;
}
