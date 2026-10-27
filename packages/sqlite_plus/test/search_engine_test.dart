import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/sql/fts5_format.dart';
import 'package:test/test.dart';

void main() {
  test('one FTS5 leaf matches the pinned Hello World record', () {
    final leaf = encodeLeaf([
      FtsPosting(Uint8List.fromList('0database'.codeUnits), [
        FtsRowPosting(BigInt.one, {
          1: [1]
        })
      ]),
      FtsPosting(Uint8List.fromList('0hello'.codeUnits), [
        FtsRowPosting(BigInt.one, {
          0: [0]
        })
      ]),
      FtsPosting(Uint8List.fromList('0sqlite'.codeUnits), [
        FtsRowPosting(BigInt.one, {
          1: [0]
        })
      ]),
      FtsPosting(Uint8List.fromList('0world'.codeUnits), [
        FtsRowPosting(BigInt.one, {
          0: [1]
        })
      ]),
    ]);
    expect(
        leaf
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase(),
        '00000034093064617461626173650106010103010568656C6C6F010202'
        '010673716C69746501060101020105776F726C64010203040F0A0D');
  });

  test('FTS5 create, match, rank, and highlight agree with the writer',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE t USING fts5(title, body)');
    await db.execute(
        "INSERT INTO t(title, body) VALUES('Hello World', 'sqlite database')");
    final rows = await db.query(
        "SELECT title, highlight(t, 0, '<', '>'), bm25(t) FROM t WHERE t MATCH 'hello'");
    expect(rows.rows.single[0], 'Hello World');
    expect(rows.rows.single[1], '<Hello> World');
    expect(rows.rows.single[2], closeTo(-1e-6, 1e-12));
    final snippet = await db.query(
        "SELECT snippet(t, 0, '<', '>', '...', 4) FROM t WHERE t MATCH 'hello'");
    expect(snippet.rows.single.single, '<Hello> World');
    final leaf = await db.query('SELECT hex(block) FROM t_data WHERE id > 100');
    expect(
        leaf.rows.single.single,
        '00000034093064617461626173650106010103010568656C6C6F010202'
        '010673716C69746501060101020105776F726C64010203040F0A0D');
  });

  test('a bound column MATCH is not parsed as extra query syntax', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE t USING fts5(title, body)');
    await db.execute(
        "INSERT INTO t(title, body) VALUES('hello OR world', 'plain')");
    await expectLater(
        db.query('SELECT title FROM t WHERE title MATCH ?', ['OR']),
        throwsA(isA<SqlException>()));
    final phrase = await db
        .query('SELECT title FROM t WHERE title MATCH ?', ['"hello OR world"']);
    expect(phrase.rows.single.single, 'hello OR world');
    await expectLater(
        db.query('SELECT title FROM t WHERE title MATCH ?', ["hello' OR 'x"]),
        throwsA(isA<SqlException>()));
  });

  test('unicode61 keeps Arabic as one token and is not a stemmer', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='unicode61')");
    await db.execute(
        "INSERT INTO t(body) VALUES('مرحبا بالعالم'), ('hello مرحبا')");
    final count =
        await db.query("SELECT count(*) FROM t WHERE t MATCH 'مرحبا'");
    expect(count.rows.single.single, BigInt.two);
    await db
        .execute("CREATE VIRTUAL TABLE a USING fts5(body, tokenize='ascii')");
    await db.execute(
        "INSERT INTO a(body) VALUES('مرحبا بالعالم'), ('hello مرحبا')");
    final ascii =
        await db.query("SELECT count(*) FROM a WHERE a MATCH 'مرحبا'");
    expect(ascii.rows.single.single, BigInt.two);
  });

  test('prefix indexes and column filters stay inside the query', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db
        .execute("CREATE VIRTUAL TABLE t USING fts5(title, body, prefix='2')");
    await db.execute(
        "INSERT INTO t(title, body) VALUES('hello', 'there'), ('world', 'hello')");
    final rows = await db.query(
        "SELECT title FROM t WHERE t MATCH 'title : hel*' ORDER BY title");
    expect(rows.rows.map((row) => row.single), ['hello']);
  });

  test('contentless, contentless-delete, and external content', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        "CREATE VIRTUAL TABLE c USING fts5(body, content='', contentless_delete=1)");
    await db.execute("INSERT INTO c(rowid, body) VALUES(5, 'hello')");
    expect((await db.query("SELECT rowid FROM c WHERE c MATCH 'hello'")).rows, [
      [BigInt.from(5)]
    ]);
    await db.execute('DELETE FROM c WHERE rowid = 5');
    expect((await db.query('SELECT count(*) FROM c')).rows.single.single,
        BigInt.zero);
    await db.execute('CREATE TABLE src(id INTEGER PRIMARY KEY, body TEXT)');
    await db.execute(
        "CREATE VIRTUAL TABLE e USING fts5(body, content='src', content_rowid='id')");
    await db.execute("INSERT INTO src(id, body) VALUES(1, 'hello')");
    await db.execute("INSERT INTO e(e) VALUES('rebuild')");
    expect((await db.query("SELECT body FROM e WHERE e MATCH 'hello'")).rows, [
      ['hello']
    ]);
    await db.execute("UPDATE src SET body = 'changed' WHERE id = 1");
    expect((await db.query("SELECT body FROM e WHERE e MATCH 'hello'")).rows, [
      ['changed']
    ]);
    expect(
        (await db.query("SELECT count(*) FROM e WHERE e MATCH 'changed'"))
            .rows
            .single
            .single,
        BigInt.zero);
  });

  test('contentful FTS update and delete refresh the index', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE t USING fts5(title, body)');
    await db.execute("INSERT INTO t(title, body) VALUES('hello', 'world')");
    await db.execute("UPDATE t SET title = 'goodbye' WHERE rowid = 1");
    final updated =
        await db.query("SELECT title, body FROM t WHERE t MATCH 'goodbye'");
    expect(updated.rows, [
      ['goodbye', 'world']
    ]);
    expect(
        (await db.query("SELECT count(*) FROM t WHERE t MATCH 'hello'"))
            .rows
            .single
            .single,
        BigInt.zero);
    await db.execute('DELETE FROM t WHERE rowid = 1');
    expect((await db.query('SELECT count(*) FROM t')).rows.single.single,
        BigInt.zero);
  });

  test('rejected search statements leave the image unchanged', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute("CREATE VIRTUAL TABLE c USING fts5(body, content='')");
    await db.execute("INSERT INTO c(rowid, body) VALUES(5, 'hello')");
    expect(
        (await db.query("SELECT rowid FROM c WHERE c MATCH 'hello'"))
            .rows
            .single
            .single,
        BigInt.from(5));
    final before = db.exportImage();
    await expectLater(db.execute("UPDATE c SET body = 'x' WHERE rowid = 5"),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('DELETE FROM c WHERE rowid = 5'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute("INSERT INTO c(c) VALUES('nope')"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('CREATE VIRTUAL TABLE t USING fts5(title, body)');
    await db.execute("INSERT INTO t(title, body) VALUES('hello', 'world')");
    final written = db.exportImage();
    await expectLater(
        db.execute(
            "INSERT INTO t(title, body) VALUES('a', 'b') RETURNING title"),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute("INSERT INTO t SELECT 'a', 'b'"),
        throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('DELETE FROM t WHERE rowid = 1 ORDER BY rowid'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('WITH x(n) AS (SELECT 1) DELETE FROM t'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('DELETE FROM t INDEXED BY missing'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), written);
    final empty = await MutableSqliteDatabase.create();
    addTearDown(empty.close);
    final blank = empty.exportImage();
    await expectLater(
        empty.execute(
            'CREATE VIRTUAL TABLE rt USING rtree(id, a, b, c, d, e, f, g, h, i, j, k)'),
        throwsA(isA<SqlException>()));
    expect(empty.exportImage(), blank);
    final opened = await MutableSqliteDatabase.fromImage(before);
    addTearDown(opened.close);
    expect(
        (await opened.query("SELECT count(*) FROM c WHERE c MATCH 'hello'"))
            .rows
            .single
            .single,
        BigInt.one);
  });

  test('rtree insert, update, and delete pass the pinned integrity check',
      () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    if (!File(cli).existsSync()) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE VIRTUAL TABLE rt USING rtree(id, minX, maxX, minY, maxY)');
    await db.execute('INSERT INTO rt VALUES(1, 0, 1, 0, 1)');
    await _expectPinned(cli, db.exportImage(),
        'PRAGMA integrity_check; SELECT id FROM rt WHERE minX <= 1 AND maxX >= 0;');
    await db.execute('UPDATE rt SET maxX = 2 WHERE id = 1');
    await _expectPinned(cli, db.exportImage(),
        'PRAGMA integrity_check; SELECT maxX FROM rt WHERE id = 1;');
    await db.execute('DELETE FROM rt WHERE id = 1');
    await _expectPinned(cli, db.exportImage(),
        'PRAGMA integrity_check; SELECT count(*) FROM rt;');
  });

  test('unimplemented FTS5 options and FTS3 writes change nothing', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    await expectLater(
        db.execute("CREATE VIRTUAL TABLE t USING fts5(body, detail='column')"),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('CREATE VIRTUAL TABLE f USING fts3(body)'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('CREATE VIRTUAL TABLE g USING fts4(body)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });

  test('rtree and geopoly round-trip rectangles and polygons', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE VIRTUAL TABLE rt USING rtree(id, minX, maxX, minY, maxY, +value)');
    await db.execute('INSERT INTO rt VALUES(1, 0, 1, 0, 1, ?)', ['aux']);
    final hit = await db.query(
        'SELECT id, value FROM rt WHERE minX <= 1 AND maxX >= 0 AND minY <= 1 AND maxY >= 0');
    expect(hit.rows, [
      [BigInt.one, 'aux']
    ]);
    final outside = await db
        .query('SELECT count(*) FROM rt WHERE minX <= -2 AND maxX >= -3');
    expect(outside.rows.single.single, BigInt.zero);
    await db.execute('DELETE FROM rt WHERE id = 1');
    expect((await db.query('SELECT count(*) FROM rt')).rows.single.single,
        BigInt.zero);
    await db.execute('CREATE VIRTUAL TABLE g USING geopoly(id)');
    await db.execute(
        "INSERT INTO g(_shape, id) VALUES('[[0,0],[1,0],[1,1],[0,1],[0,0]]', 7)");
    final area = await db
        .query('SELECT id, geopoly_area(_shape), geopoly_json(_shape) FROM g');
    expect(area.rows.single[0], BigInt.from(7));
    expect(area.rows.single[1], 1.0);
    expect(area.rows.single[2],
        '[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,1.0],[0.0,0.0]]');
    final overlap = await db
        .query("SELECT geopoly_overlap('[[0,0],[2,0],[2,2],[0,2],[0,0]]',"
            "'[[0.5,0.5],[1.5,0.5],[1.5,1.5],[0.5,1.5],[0.5,0.5]]'),"
            " geopoly_within('[[0.5,0.5],[1,0.5],[1,1],[0.5,1],[0.5,0.5]]',"
            "'[[0,0],[2,0],[2,2],[0,2],[0,0]]'),"
            " geopoly_overlap('[[0,0],[1,0],[1,1],[0,1],[0,0]]',"
            "'[[2,2],[3,2],[3,3],[2,3],[2,2]]'),"
            " geopoly_overlap('[[0,0],[2,0],[2,1],[0,1],[0,0]]',"
            "'[[1,0],[3,0],[3,1],[1,1],[1,0]]')");
    expect(overlap.rows.single,
        [BigInt.from(3), BigInt.one, BigInt.zero, BigInt.one]);
    expect(
        (await db.query("SELECT geopoly_json('nope'), geopoly_area(x'00')"))
            .rows
            .single,
        [null, null]);
  });

  test('a native FTS5 image opens and matches the pinned CLI', () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    if (!File(cli).existsSync()) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final file = File('${Directory.systemTemp.path}/sqlite_plus_fts5.db');
    if (file.existsSync()) file.deleteSync();
    final created = await Process.run(cli, [
      file.path,
      "CREATE VIRTUAL TABLE t USING fts5(title, body);"
          "INSERT INTO t(title, body) VALUES('Hello World', 'sqlite database');"
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final db = await MutableSqliteDatabase.fromImage(await file.readAsBytes());
    addTearDown(db.close);
    expect(
        (await db.query('PRAGMA integrity_check;')).rows.single.single, 'ok');
    final rows = await db.query(
        "SELECT title, highlight(t, 0, '<', '>') FROM t WHERE t MATCH 'hello'");
    expect(rows.rows.single, ['Hello World', '<Hello> World']);
    await db.execute("INSERT INTO t(title, body) VALUES('another', 'row')");
    final image = db.exportImage();
    final rewritten =
        File('${Directory.systemTemp.path}/sqlite_plus_fts5_out.db');
    await rewritten.writeAsBytes(image);
    final check = await Process.run(cli, [
      rewritten.path,
      "PRAGMA integrity_check; SELECT count(*) FROM t WHERE t MATCH 'hello';"
    ]);
    expect(check.exitCode, 0, reason: check.stderr.toString());
    expect(check.stdout.toString(), contains('ok'));
  });

  test('native FTS4 reads parentheses and rejects writes', () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    if (!File(cli).existsSync()) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final file = File('${Directory.systemTemp.path}/sqlite_plus_fts4.db');
    if (file.existsSync()) file.deleteSync();
    final created = await Process.run(cli, [
      file.path,
      "CREATE VIRTUAL TABLE t USING fts4(title, body);"
          "INSERT INTO t(title, body) VALUES('hello world', 'sqlite');"
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final bytes = await file.readAsBytes();
    final db = await MutableSqliteDatabase.fromImage(bytes);
    addTearDown(db.close);
    expect(
        (await db.query('PRAGMA integrity_check;')).rows.single.single, 'ok');
    final rows = await db.query(
        "SELECT title FROM t WHERE t MATCH '(hello AND world) OR missing'");
    expect(rows.rows.single.single, 'hello world');
    final before = db.exportImage();
    await expectLater(
        db.execute("INSERT INTO t(title, body) VALUES('more', 'text')"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });
}

Future<void> _expectPinned(String cli, Uint8List image, String sql) async {
  final file =
      File('${Directory.systemTemp.path}/sqlite_plus_rtree_${image.length}.db');
  await file.writeAsBytes(image, flush: true);
  final check = await Process.run(cli, [file.path, sql]);
  expect(check.exitCode, 0, reason: '${check.stderr}\n${check.stdout}');
  final lines = check.stdout
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  expect(lines.first, 'ok');
  expect(lines.length, greaterThan(1));
}
