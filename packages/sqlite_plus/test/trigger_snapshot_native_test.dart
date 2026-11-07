import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _cli = '/tmp/sqlite-build/sqlite3';
const _sourceId =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

Future<void> _compare(List<String> statements, List<String> queries,
    {int pageSize = 4096, int encoding = 1}) async {
  final db = await openInMemory(pageSize: pageSize, encoding: encoding);
  final folder = await Directory.systemTemp.createTemp('trigger-snapshot-');
  try {
    for (final sql in statements) {
      await db.execute(sql);
    }
    for (final sql in queries) {
      final native = await Process.run(
          _cli, ['-json', ':memory:', '${statements.join(';')};$sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final expected = native.stdout.toString().trim();
      final result = await db.query(sql);
      expect([
        for (final row in result.rows)
          {
            for (var i = 0; i < result.columns.length; i++)
              result.columns[i]:
                  row[i] is BigInt ? (row[i] as BigInt).toInt() : row[i]
          }
      ], expected.isEmpty ? [] : jsonDecode(expected), reason: sql);
    }
    final image = File('${folder.path}/image.db');
    await image.writeAsBytes(db.exportImage());
    final check =
        await Process.run(_cli, [image.path, 'PRAGMA integrity_check']);
    expect(check.exitCode, 0, reason: check.stderr.toString());
    expect(check.stdout.toString().trim(), 'ok');
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    try {
      for (final query in queries) {
        expect(
            (await reopened.query(query)).rows, (await db.query(query)).rows);
      }
    } finally {
      await reopened.close();
    }
  } finally {
    await db.close();
    await folder.delete(recursive: true);
  }
}

void main() {
  setUpAll(() async {
    final pin =
        await Process.run(_cli, [':memory:', 'SELECT sqlite_source_id()']);
    expect(pin.exitCode, 0);
    expect(pin.stdout.toString().trim(), _sourceId);
  });

  test(
      'trigger scalar reads see prior nested writes, typed columns and rollback',
      () async {
    await _compare([
      'PRAGMA recursive_triggers=ON',
      'CREATE TABLE cfg(id INTEGER PRIMARY KEY,label TEXT COLLATE NOCASE,n INTEGER,d INTEGER GENERATED ALWAYS AS(n*2) VIRTUAL)',
      "INSERT INTO cfg(id,label,n) VALUES(2,'حليب',20),(1,'Milk',10)",
      'CREATE TABLE src(id INTEGER PRIMARY KEY,n INTEGER)',
      'CREATE TABLE audit(id INTEGER PRIMARY KEY,before_n INTEGER,after_n INTEGER,control_n INTEGER,derived INTEGER,matched INTEGER)',
      "CREATE TRIGGER guard BEFORE INSERT ON src BEGIN SELECT CASE WHEN (SELECT n FROM cfg WHERE id=NEW.id) IS NULL THEN RAISE(ABORT,'missing control') END; END",
      "CREATE TRIGGER capture AFTER UPDATE ON src WHEN OLD.n IS NOT NEW.n BEGIN UPDATE cfg SET n=n+1 WHERE id=NEW.id; INSERT INTO audit(before_n,after_n,control_n,derived,matched) VALUES(OLD.n,NEW.n,(SELECT n FROM cfg WHERE id=NEW.id),(SELECT d FROM cfg WHERE id=NEW.id),(SELECT label='milk' FROM cfg WHERE id=NEW.id)); END",
      'INSERT INTO src VALUES(2,2),(1,1)',
      'BEGIN',
      'UPDATE src SET n=n+10',
      'SAVEPOINT s',
      'UPDATE src SET n=99 WHERE id=1',
      'ROLLBACK TO s',
      'RELEASE s',
      'UPDATE src SET n=n WHERE id=2',
      'COMMIT',
    ], [
      'SELECT * FROM audit ORDER BY id',
      'SELECT * FROM cfg ORDER BY id',
      'SELECT * FROM src ORDER BY id',
    ]);
  });

  for (final source in <String, (List<String>, String)>{
    'indexed': (
      ['CREATE INDEX lookup_n ON lookup(n)'],
      'SELECT n FROM lookup INDEXED BY lookup_n WHERE id=NEW.id'
    ),
    'view': (
      ['CREATE VIEW v AS SELECT id,n FROM lookup'],
      'SELECT n FROM v WHERE id=NEW.id'
    ),
    'cte': (
      [],
      'WITH v AS (SELECT id,n FROM lookup) SELECT n FROM v WHERE id=NEW.id'
    ),
    'compound': (
      [],
      'SELECT n FROM lookup WHERE id=NEW.id UNION ALL SELECT 999 LIMIT 1'
    ),
    'join': (
      [],
      'SELECT a.n FROM lookup a JOIN lookup b ON a.id=b.id WHERE b.id=NEW.id'
    ),
    'schema': ([], "SELECT count(*) FROM sqlite_schema WHERE type='table'"),
  }.entries) {
    test('trigger ${source.key} dependencies keep full snapshot semantics',
        () async {
      await _compare([
        'CREATE TABLE lookup(id INTEGER PRIMARY KEY,n INTEGER)',
        'INSERT INTO lookup VALUES(1,7)',
        ...source.value.$1,
        'CREATE TABLE src(id INTEGER PRIMARY KEY,n INTEGER)',
        'CREATE TABLE audit(n INTEGER)',
        'CREATE TRIGGER capture AFTER UPDATE ON src BEGIN INSERT INTO audit VALUES((${source.value.$2})); END',
        'INSERT INTO src VALUES(1,0)',
        'UPDATE lookup SET n=n+2',
        'UPDATE src SET n=1',
      ], [
        'SELECT * FROM audit'
      ]);
    });
  }

  test(
      'WITHOUT ROWID dependencies and trigger source-table reads remain current',
      () async {
    await _compare([
      'CREATE TABLE lookup(id TEXT PRIMARY KEY,n INTEGER) WITHOUT ROWID',
      "INSERT INTO lookup VALUES('key',7)",
      'CREATE TABLE src(id INTEGER PRIMARY KEY,n INTEGER)',
      'CREATE TABLE audit(n INTEGER,total INTEGER)',
      "CREATE TRIGGER capture AFTER INSERT ON src BEGIN INSERT INTO audit VALUES((SELECT n FROM lookup WHERE id='key'),(SELECT count(*) FROM src)); END",
      'INSERT INTO src VALUES(1,0),(2,0)',
    ], [
      'SELECT * FROM audit ORDER BY total'
    ]);
  });

  test('plain trigger subqueries see deferred whole-table increments',
      () async {
    await _compare([
      'CREATE TABLE lookup(id INTEGER PRIMARY KEY,n INTEGER)',
      'INSERT INTO lookup VALUES(1,7),(2,9)',
      'UPDATE lookup SET n=n+3',
      'CREATE TABLE src(id INTEGER PRIMARY KEY)',
      'CREATE TABLE audit(n INTEGER)',
      'CREATE TRIGGER capture AFTER INSERT ON src BEGIN INSERT INTO audit VALUES((SELECT sum(n) FROM lookup)); END',
      'INSERT INTO src VALUES(1)',
    ], [
      'SELECT * FROM audit'
    ]);
  });
  for (final encoding in [1, 2, 3]) {
    test(
        'trigger snapshot preserves Unicode and rowids on 512-byte encoding $encoding',
        () async {
      await _compare([
        'CREATE TABLE lookup(id INTEGER PRIMARY KEY,label TEXT)',
        "INSERT INTO lookup VALUES(9223372036854775807,'حليب'),(-2,'بسكويت'),(3,'milk')",
        'CREATE TABLE src(id INTEGER PRIMARY KEY)',
        'CREATE TABLE audit(label TEXT,n INTEGER)',
        'CREATE TRIGGER capture AFTER INSERT ON src WHEN NEW.id IS NOT NULL BEGIN INSERT INTO audit VALUES((SELECT label FROM lookup ORDER BY id LIMIT 1 OFFSET 1),(SELECT count(*) FROM lookup WHERE id IN (SELECT id FROM lookup))); END',
        'INSERT INTO src VALUES(1)',
      ], [
        'SELECT * FROM audit'
      ], pageSize: 512, encoding: encoding);
    });
  }
}
