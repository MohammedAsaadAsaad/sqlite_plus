import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

String? _sqliteCli() {
  final fromEnv = Platform.environment['SQLITE_PLUS_SQLITE3'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  const pinned = '/tmp/sqlite-build/sqlite3';
  if (File(pinned).existsSync()) return pinned;
  return null;
}

void main() {
  final cli = _sqliteCli();

  test('forward index and primary order match the CLI without changing ties',
      () async {
    String? identity;
    if (cli != null) {
      final version = await Process.run(cli, [
        ':memory:',
        'SELECT sqlite_version() || char(10) || sqlite_source_id();'
      ]);
      expect(version.exitCode, 0, reason: version.stderr.toString());
      identity = version.stdout.toString().trim();
      if (cli == '/tmp/sqlite-build/sqlite3') {
        expect(
            identity,
            startsWith(
                '3.53.1\n2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9'));
      }
    }
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const setup = '''
CREATE TABLE t(
  id INTEGER PRIMARY KEY,
  a INT,
  b TEXT COLLATE NOCASE,
  c REAL
);
CREATE INDEX ia ON t(a);
CREATE INDEX iab ON t(a, b);
CREATE INDEX ib_desc ON t(b DESC);
CREATE INDEX partial ON t(a) WHERE a > 0;
CREATE INDEX expr ON t(abs(a));
CREATE TABLE wide(id INTEGER PRIMARY KEY, a TEXT, b TEXT) WITHOUT ROWID;
CREATE INDEX wide_b ON wide(b);
INSERT INTO t(id,a,b,c) VALUES
  (1,NULL,'b',1),
  (2,1,'B',1.5),
  (3,-2,'a',NULL),
  (4,1,'a',2),
  (5,NULL,'A',0),
  (6,3,'c',3);
INSERT INTO wide(id,a,b) VALUES (2,'z','m'),(1,'a','m'),(3,'a','a');
''';
    for (final sql in setup.split(';')) {
      if (sql.trim().isEmpty) continue;
      await db.execute(sql);
    }
    const queries = [
      'SELECT id FROM t ORDER BY id',
      'SELECT id FROM t ORDER BY id DESC',
      'SELECT b, id FROM t ORDER BY id, b DESC',
      'SELECT a, id FROM wide ORDER BY id, a DESC',
      'SELECT a, b, id FROM t INDEXED BY iab WHERE a = 1 ORDER BY b, id',
      'SELECT id FROM t ORDER BY id DESC LIMIT 2',
      'SELECT id FROM t ORDER BY id DESC LIMIT 1 OFFSET 1',
      "SELECT id FROM t WHERE b = 'a' ORDER BY id LIMIT 1",
      'SELECT a, id FROM t ORDER BY a, id',
      'SELECT a FROM t ORDER BY a',
      'SELECT a FROM t ORDER BY a DESC',
      'SELECT b FROM t ORDER BY b',
      'SELECT a, b FROM t ORDER BY a, b',
      'SELECT b, id FROM t ORDER BY b DESC, id',
      'SELECT b, id FROM t ORDER BY b COLLATE NOCASE, id',
      'SELECT b, id FROM t ORDER BY b COLLATE binary, id',
      'SELECT a, b FROM t WHERE a = 1',
      'SELECT a FROM t WHERE a = 1 ORDER BY b',
      'SELECT a, b FROM t WHERE a = 1 ORDER BY b DESC',
      'SELECT a FROM t NOT INDEXED ORDER BY a',
      'SELECT abs(a), id FROM t ORDER BY abs(a), id',
      'SELECT * FROM t ORDER BY a, id',
      'SELECT id, a FROM t AS src ORDER BY src.a, src.id',
      'SELECT a, id FROM wide ORDER BY a, id',
      'SELECT b, id FROM wide ORDER BY b, id',
      "SELECT a, id FROM t ORDER BY a NULLS LAST, id",
    ];
    for (final query in queries) {
      final actual = await db.query(query);
      if (cli == null) continue;
      final native =
          await Process.run(cli, ['-json', ':memory:', '$setup $query;']);
      expect(native.exitCode, 0, reason: '$query\n${native.stderr}');
      final expected = native.stdout.toString().trim().isEmpty
          ? <Object?>[]
          : jsonDecode(native.stdout.toString()) as List;
      expect(_rows(actual), expected, reason: '$query via $identity');
    }
    final reader =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    addTearDown(reader.close);
    expect(reader.explain('SELECT id FROM t ORDER BY id').access, 'table-scan');
    expect(reader.explain('SELECT id FROM t ORDER BY id').scanSatisfiesOrder,
        isTrue);
    expect(
        reader
            .explain('SELECT b, id FROM t ORDER BY id, b DESC')
            .scanSatisfiesOrder,
        isTrue);
    expect(
        reader.explain('SELECT id FROM t ORDER BY id DESC').scanSatisfiesOrder,
        isTrue);
    expect(reader.explain('SELECT id FROM t ORDER BY id DESC').scanReverse,
        isTrue);
    expect(reader.explain('SELECT a FROM t ORDER BY a').access,
        'secondary-index-scan');
    expect(reader.explain('SELECT a FROM t ORDER BY a').indexName, 'ia');
    expect(reader.explain('SELECT a FROM t ORDER BY a DESC').indexName, 'ia');
    expect(
        reader.explain('SELECT a FROM t ORDER BY a DESC').scanReverse, isTrue);
    expect(reader.explain('SELECT b FROM t ORDER BY b').indexName, 'ib_desc');
    expect(reader.explain('SELECT b FROM t ORDER BY b').scanReverse, isTrue);
    expect(reader.explain('SELECT * FROM t ORDER BY a').access, 'table-scan');
    expect(reader.explain('SELECT a FROM t NOT INDEXED ORDER BY a').access,
        'table-scan');
    expect(reader.explain('SELECT abs(a) FROM t ORDER BY abs(a)').access,
        'table-scan');
    expect(reader.explain('SELECT a, b FROM t ORDER BY a, b').indexName, 'iab');
    expect(
        reader.explain('SELECT a, b FROM t ORDER BY a, b').scanSatisfiesOrder,
        isTrue);
    expect(
        reader.explain('SELECT a, b FROM t WHERE a = 1 ORDER BY b').indexName,
        'iab');
    expect(reader.explain('SELECT a, b FROM t WHERE a = 1 ORDER BY b').covering,
        isTrue);
    expect(
        reader
            .explain('SELECT a, b FROM t WHERE a = 1 ORDER BY b')
            .scanSatisfiesOrder,
        isTrue);
    expect(reader.explain('SELECT a, b FROM t WHERE a = 1').indexName, 'iab');
    expect(reader.explain('SELECT a, b FROM t WHERE a = 1').covering, isTrue);
    expect(
        reader
            .explain('SELECT a, b FROM t INDEXED BY iab WHERE a = 1 ORDER BY b')
            .scanSatisfiesOrder,
        isTrue);
    expect(
        reader
            .explain(
                'SELECT a, b, id FROM t INDEXED BY iab WHERE a = 1 ORDER BY b, id')
            .orderedPrefix,
        1);
    expect(
        reader.explain('SELECT b FROM t ORDER BY b DESC').indexName, 'ib_desc');
    expect(
        reader
            .explain('SELECT a, b FROM t WHERE a = 1 ORDER BY b DESC')
            .scanSatisfiesOrder,
        isFalse);
    expect(reader.explain('SELECT id, a FROM t AS src ORDER BY src.a').access,
        isNot('secondary-index-scan'));
    final limited =
        await reader.diagnoseQuery('SELECT id FROM t ORDER BY id DESC LIMIT 1');
    expect(limited.rowsLoaded, 1);
    expect(limited.result.rows.single.single, BigInt.from(6));
    final filtered = await reader
        .diagnoseQuery("SELECT id FROM t WHERE b = 'a' ORDER BY id LIMIT 1");
    expect(filtered.rowsLoaded, greaterThan(1));
    expect(filtered.result.rows.single.single, BigInt.from(3));
  });
}

List<Map<String, Object?>> _rows(QueryResult result) => [
      for (final row in result.rows)
        {
          for (var i = 0; i < result.columns.length; i++)
            result.columns[i]:
                row[i] is BigInt ? (row[i] as BigInt).toInt() : row[i]
        }
    ];
