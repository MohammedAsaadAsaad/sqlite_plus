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

  Future<String?> pinnedCli() async {
    final tool = cli();
    if (!File(tool).existsSync()) return null;
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  test('correlated json_each and json_tree match the pinned CLI', () async {
    final tool = await pinnedCli();
    if (tool == null) fail('pinned sqlite3 is missing');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const setup = '''
      CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT);
      INSERT INTO docs VALUES
        (1,'{"a":1,"b":[2]}'),
        (2,'[10,20]'),
        (3,NULL),
        (5,'"txt"'),
        (6,'[]'),
        (7,'{}')
    ''';
    for (final statement in setup.split(';')) {
      final text = statement.trim();
      if (text.isNotEmpty) await db.execute(text);
    }
    Future<void> match(String sql) async {
      final engine = (await db.query(sql)).rows.single.single?.toString() ?? '';
      final result = await Process.run(
          tool, [':memory:', '.mode list', '.headers off', setup, sql]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
      expect(engine, result.stdout.toString().trimRight(), reason: sql);
    }

    const pack =
        "group_concat(quote(id)||','||quote(k)||','||quote(v), char(10))";
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM docs, json_each(docs.label) e
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM json_each(docs.label) e, docs
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM docs LEFT JOIN json_each(docs.label) e ON 1
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM docs JOIN json_each(docs.label) e ON e.type = 'integer'
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, NULL AS k, e.value AS v
        FROM docs, json_each(docs.label, '\$.b') e
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT group_concat(quote(id)||','||quote(fullkey)||','||quote(atom), char(10))
      FROM (
        SELECT docs.id AS id, e.fullkey AS fullkey, e.atom AS atom
        FROM docs, json_tree(docs.label) e
        WHERE e.atom IS NOT NULL
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT group_concat(quote(k)||','||quote(v), char(10)) FROM (
        SELECT j.key AS k, e.value AS v
        FROM json_each('{"a":[1,2]}') j, json_each(j.value) e
        ORDER BY e.id
      )
    ''');
    await match(
        "SELECT count(*) FROM json_each((SELECT label FROM docs WHERE id=1))");
    await match(
        'SELECT count(*) FROM json_each(docs.label) e RIGHT JOIN docs ON 1');
    await match(
        'SELECT count(*) FROM json_tree(docs.label) e RIGHT JOIN docs ON 1');
    await match(
        'SELECT count(*) FROM json_each(docs.label) e FULL JOIN docs ON 1');
    await match(
        'SELECT count(*) FROM json_each(docs.label) e LEFT JOIN docs ON 1');
    await match('SELECT count(*) FROM json_each(label) e RIGHT JOIN docs ON 1');
    await match(
        'SELECT count(*) FROM json_each(main.docs.label) e RIGHT JOIN docs ON 1');
    await expectLater(
        db.query(
            'SELECT count(*) FROM json_each(missing) e RIGHT JOIN docs ON 1'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such column: missing')));
    final missingCli = await Process.run(tool, [
      ':memory:',
      setup,
      'SELECT count(*) FROM json_each(missing) e RIGHT JOIN docs ON 1'
    ]);
    expect(missingCli.exitCode, isNot(0));
    expect(missingCli.stderr.toString(), contains('no such column: missing'));
    await expectLater(
        db.query(
            'SELECT count(*) FROM json_each(docs.nope) e RIGHT JOIN docs ON 1'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such column: docs.nope')));
    final typoCli = await Process.run(tool, [
      ':memory:',
      setup,
      'SELECT count(*) FROM json_each(docs.nope) e RIGHT JOIN docs ON 1'
    ]);
    expect(typoCli.exitCode, isNot(0));
    expect(typoCli.stderr.toString(), contains('no such column: docs.nope'));
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM docs RIGHT JOIN json_each(docs.label) e ON 1
        ORDER BY docs.id, e.id
      )
    ''');
    await match('''
      SELECT $pack FROM (
        SELECT docs.id AS id, e.key AS k, e.value AS v
        FROM docs FULL JOIN json_each(docs.label) e ON 1
        ORDER BY docs.id, e.id
      )
    ''');

    final bad = await MutableSqliteDatabase.create();
    addTearDown(bad.close);
    await bad.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT)');
    await bad.execute("INSERT INTO docs VALUES(1,'{\"a\":1}'),(2,'nope')");
    await expectLater(
        bad.query('SELECT docs.id, e.key FROM docs, json_each(docs.label) e'),
        throwsA(isA<SqlException>()
            .having((error) => error.message, 'message', 'malformed JSON')));
    final cliBad = await Process.run(tool, [
      ':memory:',
      "CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT); "
          "INSERT INTO docs VALUES(1,'{\"a\":1}'),(2,'nope'); "
          "SELECT docs.id, e.key FROM docs, json_each(docs.label) e;"
    ]);
    expect(cliBad.exitCode, isNot(0));
    expect(cliBad.stderr.toString(), contains('malformed JSON'));
  });
}
