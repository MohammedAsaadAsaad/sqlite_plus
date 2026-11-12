import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/btree/database_image_builder.dart';
import 'package:test/test.dart';

void main() {
  test('TEMP tables and indexes stay out of the exported image', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute("INSERT INTO t VALUES('main')");
    await db.execute('CREATE TEMP TABLE t(v)');
    await db.execute('CREATE INDEX i ON t(v)');
    await db.execute("INSERT INTO t VALUES('temp')");
    expect((await db.query('SELECT v FROM t')).rows, [
      ['temp']
    ]);
    expect((await db.query('SELECT v FROM temp.t')).rows, [
      ['temp']
    ]);
    expect((await db.query('SELECT v FROM main.t')).rows, [
      ['main']
    ]);
    expect(
        (await db.query(
                "SELECT name FROM temp.sqlite_schema WHERE type='index'"))
            .rows,
        [
          ['i']
        ]);
    expect(
        (await db.query(
                "SELECT name FROM sqlite_schema WHERE name='i' OR name='t'"))
            .rows,
        [
          ['t']
        ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect((await reopened.query('SELECT v FROM t')).rows, [
      ['main']
    ]);
    await expectLater(
        reopened.query('SELECT v FROM temp.t'), throwsA(isA<SqlException>()));
    expect((await db.query('PRAGMA database_list')).rows, [
      [BigInt.zero, 'main', ''],
      [BigInt.one, 'temp', '']
    ]);
  });

  test('TEMP views and triggers shadow permanent names', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE p(v)');
    await db.execute("INSERT INTO p VALUES('permanent')");
    await db.execute("CREATE TEMP VIEW p AS SELECT 'shadow' AS v");
    expect((await db.query('SELECT v FROM p')).rows, [
      ['shadow']
    ]);
    expect((await db.query('SELECT v FROM main.p')).rows, [
      ['permanent']
    ]);
    await db.execute('CREATE TEMP TABLE g(v)');
    await db.execute(
        "CREATE TEMP TRIGGER tr AFTER INSERT ON g BEGIN UPDATE g SET v=v||'!'; END");
    await db.execute("INSERT INTO g VALUES('z')");
    expect((await db.query('SELECT v FROM g')).rows, [
      ['z!']
    ]);
    expect(
        (await db.query(
                "SELECT name FROM temp.sqlite_schema WHERE type='trigger'"))
            .rows,
        [
          ['tr']
        ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect((await reopened.query('SELECT v FROM p')).rows, [
      ['permanent']
    ]);
    await expectLater(
        reopened.query('SELECT * FROM g'), throwsA(isA<SqlException>()));
  });

  test('ATTACH and DETACH keep one extra database inside the limit', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await expectLater(
        db.execute("ATTACH 'missing.db' AS aux"), throwsA(isA<SqlException>()));
    await db.execute("ATTACH ':memory:' AS aux");
    await db.execute('CREATE TABLE aux.u(v)');
    await db.execute("INSERT INTO aux.u VALUES('attached')");
    expect((await db.query('SELECT aux.u.v FROM aux.u')).rows, [
      ['attached']
    ]);
    await expectLater(
        db.execute("ATTACH ':memory:' AS aux"), throwsA(isA<SqlException>()));
    await expectLater(
        db.execute("ATTACH ':memory:' AS main"), throwsA(isA<SqlException>()));
    await expectLater(
        db.execute("ATTACH ':memory:' AS temp"), throwsA(isA<SqlException>()));
    await expectLater(db.execute("ATTACH ':memory:' AS second"),
        throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('DETACH missing'), throwsA(isA<SqlException>()));
    final directory =
        Directory.systemTemp.createTempSync('sqlite-plus-attach-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final huge = File('${directory.path}/huge.db');
    await huge.writeAsBytes(Uint8List(64 * 1024 * 1024 + 1));
    db.attachFile =
        (path) async => Uint8List.fromList(await File(path).readAsBytes());
    await expectLater(db.execute("ATTACH '${huge.path}' AS extra"),
        throwsA(isA<SqlException>()));
    final missing = File('${directory.path}/absent.db');
    db.attachFile = (path) async {
      final file = File(path);
      if (!file.existsSync()) {
        throw SqlException('unable to open database: $path');
      }
      return Uint8List.fromList(await file.readAsBytes());
    };
    await expectLater(db.execute("ATTACH '${missing.path}' AS extra"),
        throwsA(isA<SqlException>()));
    final other = await MutableSqliteDatabase.create();
    await other.execute('CREATE TABLE file_row(v)');
    await other.execute("INSERT INTO file_row VALUES('from-file')");
    final path = '${directory.path}/other.db';
    await File(path).writeAsBytes(other.exportImage());
    await other.close();
    await db.execute('DETACH aux');
    await db.execute("ATTACH '$path' AS aux");
    expect((await db.query('SELECT v FROM aux.file_row')).rows, [
      ['from-file']
    ]);
    expect((await db.query('PRAGMA database_list')).rows, [
      [BigInt.zero, 'main', ''],
      [BigInt.one, 'aux', '']
    ]);
    final exported = db.exportImage();
    await db.execute('DETACH DATABASE aux');
    final reopened = await MutableSqliteDatabase.fromImage(exported);
    addTearDown(reopened.close);
    await expectLater(
        reopened.query('SELECT * FROM file_row'), throwsA(isA<SqlException>()));
    await expectLater(reopened.query('SELECT * FROM aux.file_row'),
        throwsA(isA<SqlException>()));
  });

  test('qualified names resolve conflicts and a temp update writes main',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute("INSERT INTO t VALUES('main')");
    await db.execute('CREATE TEMP TABLE t(v)');
    await db.execute("INSERT INTO temp.t VALUES('temp')");
    expect((await db.query('SELECT main.t.v FROM main.t')).rows, [
      ['main']
    ]);
    expect((await db.query('SELECT temp.t.v FROM temp.t')).rows, [
      ['temp']
    ]);
    expect(
        (await db.query('SELECT main.t.v, temp.t.v FROM main.t, temp.t')).rows,
        [
          ['main', 'temp']
        ]);
    expect(
        (await db.execute("UPDATE main.t SET v=(SELECT v FROM temp.t)"))
            .changes,
        1);
    expect((await db.query('SELECT v FROM main.t')).rows, [
      ['temp']
    ]);
    expect((await db.query('SELECT v FROM temp.t')).rows, [
      ['temp']
    ]);
  });

  test('a transaction snapshots main and temp together', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES('kept')");
    await db.execute('CREATE TEMP TABLE u(v)');
    await db.execute("INSERT INTO u VALUES('temp')");
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT * FROM t')).rows, isEmpty);
    await expectLater(
        db.query('SELECT * FROM u'), throwsA(isA<SqlException>()));
    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES('kept')");
    await db.execute('CREATE TEMP TABLE u(v)');
    await db.execute("INSERT INTO u VALUES('temp')");
    await db.execute('COMMIT');
    expect((await db.query('SELECT v FROM t')).rows, [
      ['kept']
    ]);
    expect((await db.query('SELECT v FROM temp.u')).rows, [
      ['temp']
    ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect((await reopened.query('SELECT v FROM t')).rows, [
      ['kept']
    ]);
    await expectLater(
        reopened.query('SELECT * FROM u'), throwsA(isA<SqlException>()));
  });

  test('journal_mode on memory stays memory without rewriting the image',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    expect(
        (await db.query('PRAGMA journal_mode')).rows.single.single, 'memory');
    expect(sqlJournalMode(before[18]), 'rollback');
    for (final mode in [
      'memory',
      'off',
      'delete',
      'persist',
      'truncate',
      'wal',
      'rollback',
      'nope'
    ]) {
      expect((await db.query('PRAGMA journal_mode=$mode')).rows.single.single,
          'memory',
          reason: mode);
      expect(db.exportImage(), before, reason: mode);
    }
    expect((await db.query('PRAGMA temp.journal_mode')).rows.single.single,
        'delete');
    expect((await db.query('PRAGMA temp.journal_mode=off')).rows.single.single,
        'delete');
    expect(
        (await db.query('PRAGMA temp.journal_mode=memory')).rows.single.single,
        'memory');
    expect(db.exportImage(), before);
    final wal = Uint8List.fromList(before);
    wal[18] = 2;
    wal[19] = 2;
    expect(sqlJournalMode(DatabaseHeader.decode(wal).writeVersion), 'wal');
    await expectLater(
        MutableSqliteDatabase.fromImage(wal), throwsUnsupportedError);
  });

  test('cache_size, busy_timeout, and synchronous stay off the image',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    expect((await db.query('PRAGMA cache_size')).rows.single.single,
        BigInt.from(-2000));
    expect((await db.query('PRAGMA busy_timeout')).rows.single.single,
        BigInt.zero);
    expect(
        (await db.query('PRAGMA synchronous')).rows.single.single, BigInt.two);
    await db.execute('PRAGMA cache_size=-100');
    await db.execute('PRAGMA busy_timeout=15');
    await db.execute('PRAGMA synchronous=OFF');
    expect((await db.query('PRAGMA cache_size')).rows.single.single,
        BigInt.from(-100));
    expect((await db.query('PRAGMA busy_timeout')).rows.single.single,
        BigInt.from(15));
    expect(
        (await db.query('PRAGMA synchronous')).rows.single.single, BigInt.zero);
    expect(db.exportImage(), before);
    await expectLater(
        db.execute('PRAGMA cache_size=0'), throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('PRAGMA busy_timeout=-1'), throwsA(isA<SqlException>()));
  });

  test('auto_vacuum on a fresh connection is stored in the header', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect(
        (await db.query('PRAGMA auto_vacuum')).rows.single.single, BigInt.zero);
    expect((await db.query('PRAGMA auto_vacuum=1')).rows, isEmpty);
    expect(
        (await db.query('PRAGMA auto_vacuum')).rows.single.single, BigInt.one);
    expect(DatabaseHeader.decode(db.exportImage()).largestRootPage, 1);
    final opened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(opened.close);
    expect((await opened.query('PRAGMA auto_vacuum')).rows.single.single,
        BigInt.one);
    final vacuum = Uint8List.fromList(DatabaseImageBuilder.empty());
    ByteData.sublistView(vacuum).setUint32(52, 2);
    await expectLater(
        MutableSqliteDatabase.fromImage(vacuum), throwsUnsupportedError);
    final pager = await ReadOnlyPager.open(ByteImageStorage(vacuum));
    addTearDown(pager.close);
    expect(pager.header.autoVacuumMode, 1);
    expect(pager.header.largestRootPage, 2);
  });

  test('a custom collation orders, indexes, and rejects duplicates', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.functions.createCollation('rev', (a, b) => b.compareTo(a));
    await db.execute('CREATE TABLE t(v TEXT COLLATE rev UNIQUE)');
    await db.execute('CREATE INDEX i ON t(v)');
    await db.execute("INSERT INTO t VALUES('a'),('b'),('c')");
    await expectLater(
        db.execute("INSERT INTO t VALUES('b')"), throwsA(isA<SqlException>()));
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows, [
      ['c'],
      ['b'],
      ['a']
    ]);
    expect((await db.query("SELECT v FROM t WHERE v='a'")).rows, [
      ['a']
    ]);
  });

  test('EXPLAIN QUERY PLAN is this engine plan, not bytecode', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final explained = await db.query('EXPLAIN SELECT * FROM t');
    expect(explained.columns,
        ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment']);
    expect(explained.rows.map((row) => row[1]), contains('OpenRead'));
    final plan = await db.query('EXPLAIN QUERY PLAN SELECT * FROM t');
    expect(plan.columns, ['id', 'parent', 'notused', 'detail']);
    expect(plan.rows.single[3].toString(), 'SCAN t');
    expect(plan.rows.single[3].toString(), isNot(contains('Opcode')));
  });

  test('sqlite_stat4 is stored and is not used for planning', () async {
    final image = DatabaseImageBuilder.build(DatabaseImageBuilder.empty(), [
      ImageObject('table', 't', 't', 'CREATE TABLE t(v)', tableRows: [
        TableRow(BigInt.one, ['kept'])
      ]),
      ImageObject('table', 'sqlite_stat4', 'sqlite_stat4',
          'CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)',
          tableRows: [
            TableRow(BigInt.one, ['t', null, '9', '9', '9', null])
          ])
    ]);
    final db = await MutableSqliteDatabase.fromImage(image);
    addTearDown(db.close);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['kept']
    ]);
    expect((await db.query('SELECT neq FROM sqlite_stat4')).rows, [
      ['9']
    ]);
    final plan = await db.query('EXPLAIN QUERY PLAN SELECT v FROM t');
    expect(plan.rows.single[3].toString(), isNot(contains('stat4')));
  });

  test('four comma joins reorder by sqlite_stat1 row counts', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(v)');
    await db.execute('CREATE TABLE b(v)');
    await db.execute('CREATE TABLE c(v)');
    await db.execute('CREATE TABLE d(v)');
    await db.execute("INSERT INTO a VALUES('a')");
    await db.execute("INSERT INTO b VALUES('b1'),('b2')");
    await db.execute("INSERT INTO c VALUES('c1'),('c2'),('c3')");
    await db.execute(
        "INSERT INTO d VALUES('d1'),('d2'),('d3'),('d4'),('d5'),('d6'),('d7'),('d8')");
    await db.execute('ANALYZE');
    const query = 'SELECT a.v AS av, b.v AS bv, c.v AS cv, d.v AS dv '
        'FROM d, c, b, a ORDER BY av, bv, cv, dv LIMIT 2';
    final plan = await db.query('EXPLAIN QUERY PLAN $query');
    expect(plan.rows.first[3].toString(), contains('a'));
    expect(plan.rows.last[3].toString(), contains('d'));
    final five = await db.query(
        'EXPLAIN QUERY PLAN SELECT a.v FROM d, c, b, a, a AS extra ORDER BY a.v');
    expect(five.rows.first[3].toString(), contains('d'));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = "CREATE TABLE a(v); CREATE TABLE b(v); CREATE TABLE c(v); "
        "CREATE TABLE d(v); INSERT INTO a VALUES('a'); "
        "INSERT INTO b VALUES('b1'),('b2'); "
        "INSERT INTO c VALUES('c1'),('c2'),('c3'); "
        "INSERT INTO d VALUES('d1'),('d2'),('d3'),('d4'),('d5'),('d6'),('d7'),('d8');";
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $query;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query(query);
    final expected = jsonDecode(native.stdout.toString()) as List;
    expect(actual.rows.length, expected.length);
    for (var i = 0; i < actual.rows.length; i++) {
      expect([
        for (final value in actual.rows[i])
          value is BigInt ? value.toInt() : value
      ], (expected[i] as Map).values.toList());
    }
  });

  test('two comma joins reorder by sqlite_stat1 row counts', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE small(v)');
    await db.execute('CREATE TABLE big(v)');
    await db.execute("INSERT INTO small VALUES('s')");
    final values = [
      for (var i = 0; i < 40; i++) "('${i.toString().padLeft(4, '0')}')"
    ].join(',');
    await db.execute('INSERT INTO big(v) VALUES $values');
    await db.execute('ANALYZE');
    final plan = await db.query(
        'EXPLAIN QUERY PLAN SELECT big.v, small.v FROM big, small ORDER BY big.v');
    expect(plan.rows.first[3].toString(), contains('small'));
    expect(plan.rows.last[3].toString(), contains('big'));
    expect(
        (await db.query(
                'SELECT big.v, small.v FROM big, small ORDER BY big.v LIMIT 2'))
            .rows,
        [
          ['0000', 's'],
          ['0001', 's']
        ]);
  });

  test('a covering index does not return to the table', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a, b, c)');
    await db.execute('CREATE INDEX i ON t(a, b)');
    await db.execute("INSERT INTO t VALUES(1, 'b', 'c')");
    final image = db.exportImage();
    final covered = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(covered.close);
    expect((await covered.query('SELECT a, b FROM t WHERE a=1')).rows, [
      [BigInt.one, 'b']
    ]);
    final coveredPages = covered.pagesRead;
    final full = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(full.close);
    expect((await full.query('SELECT a, c FROM t WHERE a=1')).rows, [
      [BigInt.one, 'c']
    ]);
    expect(coveredPages, lessThan(full.pagesRead));
    final plan =
        await db.query('EXPLAIN QUERY PLAN SELECT a, b FROM t WHERE a=1');
    expect(plan.rows.single[3].toString(), contains('COVERING'));
  });

  test('double quotes stay identifiers while DQS is off', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(title)');
    await db.execute("INSERT INTO t VALUES('value')");
    expect((await db.query('SELECT title FROM t')).rows, [
      ['value']
    ]);
    expect((await db.query('SELECT "title" FROM t')).rows, [
      ['value']
    ]);
    expect((await db.query("SELECT 'title' FROM t")).rows, [
      ['title']
    ]);
    await expectLater(
        db.query('SELECT "missing" FROM t'), throwsA(isA<SqlException>()));
  });

  test('constraint, syntax, and missing-table errors keep stable codes',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v UNIQUE)');
    await db.execute("INSERT INTO t VALUES('a')");
    Future<SqlException> capture(Future<Object?> action) async {
      try {
        await action;
      } on SqlException catch (error) {
        return error;
      }
      throw StateError('expected SqlException');
    }

    expect((await capture(db.query('SELECT * FROM missing'))).errorCode,
        SqlErrorCode.missingTable);
    expect((await capture(db.query('SELECT 1 trailing junk'))).errorCode,
        SqlErrorCode.syntax);
    expect((await capture(db.execute("INSERT INTO t VALUES('a')"))).errorCode,
        SqlErrorCode.constraint);
  });

  test('AND and OR skip the right side once the left side decides', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 7;
    });
    expect((await db.query('SELECT 0 AND probe()')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT 1 OR probe()')).rows, [
      [BigInt.one]
    ]);
    expect(calls, 0);
    expect((await db.query('SELECT 1 AND probe()')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('SELECT 0 OR probe()')).rows, [
      [BigInt.one]
    ]);
    expect(calls, 2);
    expect((await db.query('SELECT NULL AND 0')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT NULL OR 1')).rows, [
      [BigInt.one]
    ]);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (File(pinned).existsSync()) {
      for (final query in [
        'SELECT 0 AND 1',
        'SELECT 1 OR 0',
        'SELECT NULL AND 0',
        'SELECT NULL OR 1',
        'SELECT NULL AND NULL',
        'SELECT 1 AND 1',
      ]) {
        final native =
            await Process.run(pinned, ['-json', ':memory:', '$query;']);
        expect(native.exitCode, 0, reason: native.stderr.toString());
        final actual = await db.query(query);
        final expected = jsonDecode(native.stdout.toString()) as List;
        expect(actual.rows.length, expected.length, reason: query);
        for (var i = 0; i < actual.rows.length; i++) {
          final left = actual.rows[i].single;
          final right = (expected[i] as Map).values.single;
          expect(left is BigInt ? left.toInt() : left, right, reason: query);
        }
      }
    }
  });

  test('an indexed inner join seeks the leading column', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY, k INT, v TEXT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db
        .execute('INSERT INTO a VALUES (1, 10), (2, NULL), (3, 20), (4, 10)');
    await db.execute(
        "INSERT INTO b VALUES (1, 10, 'x'), (2, 10, 'y'), (3, NULL, 'n'), (4, 30, 'z')");
    const query =
        'SELECT a.id AS aid, b.id AS bid, b.v FROM a INNER JOIN b ON a.k = b.k '
        'ORDER BY aid, bid';
    final plan = await db.query('EXPLAIN QUERY PLAN $query');
    expect(plan.rows.first[3].toString(), contains('SCAN a'));
    expect(plan.rows.last[3].toString(), 'SEARCH b USING INDEX bk (k=?)');
    const extra =
        "SELECT a.id AS aid, b.id AS bid FROM a INNER JOIN b ON a.k = b.k AND b.v = 'x' "
        'ORDER BY aid, bid';
    expect(
        (await db.query('EXPLAIN QUERY PLAN $extra')).rows.last[3].toString(),
        'SEARCH b USING INDEX bk (k=?)');
    const disjunction =
        'SELECT a.id AS aid, b.id AS bid FROM a INNER JOIN b ON a.k = b.k OR a.id = b.id '
        'ORDER BY aid, bid';
    expect(
        (await db.query('EXPLAIN QUERY PLAN $disjunction'))
            .rows
            .last[3]
            .toString(),
        contains('SCAN b'));
    const leftJoin =
        'SELECT a.id AS aid, b.v FROM a LEFT JOIN b ON a.k = b.k ORDER BY aid, b.id';
    expect(
        (await db.query('EXPLAIN QUERY PLAN $leftJoin'))
            .rows
            .last[3]
            .toString(),
        contains('SCAN b'));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE a(id INTEGER PRIMARY KEY, k INT); '
        'CREATE TABLE b(id INTEGER PRIMARY KEY, k INT, v TEXT); '
        'CREATE INDEX bk ON b(k); '
        'INSERT INTO a VALUES (1, 10), (2, NULL), (3, 20), (4, 10); '
        "INSERT INTO b VALUES (1, 10, 'x'), (2, 10, 'y'), (3, NULL, 'n'), (4, 30, 'z');";
    for (final sql in [query, extra, disjunction, leftJoin]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final expected = jsonDecode(native.stdout.toString()) as List;
      expect(actual.rows.length, expected.length, reason: sql);
      for (var i = 0; i < actual.rows.length; i++) {
        expect([
          for (final value in actual.rows[i])
            value is BigInt ? value.toInt() : value
        ], (expected[i] as Map).values.toList(), reason: sql);
      }
    }
  });

  test('uncorrelated EXISTS stops after the first match', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE TABLE empty(id INTEGER PRIMARY KEY)');
    final values = [for (var i = 1; i <= 4000; i++) '($i, $i)'].join(',');
    await db.execute('INSERT INTO b(id, k) VALUES $values');
    await db.execute('INSERT INTO a VALUES (1, 1), (2, 4000), (3, 7)');
    var calls = 0;
    db.functions.registerScalar('probe', 1, (_) {
      calls++;
      return 1;
    });
    expect(
        (await db.query(
                'SELECT EXISTS(SELECT 1 FROM b WHERE probe(k) OR k = -1)'))
            .rows,
        [
          [BigInt.one]
        ]);
    expect(calls, 1);
    expect(
        (await db.query('SELECT EXISTS(SELECT 1 FROM b WHERE k = -1)')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT EXISTS(SELECT count(*) FROM empty)')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('SELECT EXISTS(SELECT 1 FROM empty)')).rows, [
      [BigInt.zero]
    ]);
    final image = db.exportImage();
    final stopped = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(stopped.close);
    final before = stopped.pagesRead;
    expect(
        (await stopped.query('SELECT EXISTS(SELECT 1 FROM b WHERE k = 1)'))
            .rows,
        [
          [BigInt.one]
        ]);
    final existsPages = stopped.pagesRead - before;
    final full = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(full.close);
    final beforeFull = full.pagesRead;
    await full.query('SELECT count(*) FROM b');
    expect(existsPages, lessThan(full.pagesRead - beforeFull));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const correlated =
        'SELECT a.id AS aid FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.k = a.k) ORDER BY aid';
    final setup = 'CREATE TABLE b(id INTEGER PRIMARY KEY, k INT); '
        'CREATE TABLE a(id INTEGER PRIMARY KEY, k INT); '
        'INSERT INTO b(id, k) VALUES $values; '
        'INSERT INTO a VALUES (1, 1), (2, 4000), (3, 7);';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $correlated;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query(correlated);
    final expected = jsonDecode(native.stdout.toString()) as List;
    expect([
      for (final row in actual.rows)
        for (final value in row) value is BigInt ? value.toInt() : value
    ], [
      for (final row in expected) ...(row as Map).values
    ]);
  });

  test('an uncorrelated scalar subquery runs once', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE b(v INT)');
    await db.execute('INSERT INTO a VALUES (1), (2), (3), (4)');
    await db.execute('INSERT INTO b VALUES (1), (2)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 10;
    });
    final reused =
        await db.query('SELECT id, (SELECT probe()) AS p FROM a ORDER BY id');
    expect(calls, 1);
    expect(reused.rows, [
      [BigInt.one, BigInt.from(10)],
      [BigInt.two, BigInt.from(10)],
      [BigInt.from(3), BigInt.from(10)],
      [BigInt.from(4), BigInt.from(10)]
    ]);
    calls = 0;
    const correlated =
        'SELECT a.id AS aid, (SELECT count(*) FROM b WHERE b.v = a.id) AS n '
        'FROM a ORDER BY aid';
    final actual = await db.query(correlated);
    expect(calls, 0);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE a(id INTEGER PRIMARY KEY); '
        'CREATE TABLE b(v INT); '
        'INSERT INTO a VALUES (1), (2), (3), (4); '
        'INSERT INTO b VALUES (1), (2);';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $correlated;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final expected = jsonDecode(native.stdout.toString()) as List;
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in expected) (row as Map).values.toList()
    ]);
  });

  test('pure arithmetic folds and functions stay', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES (1), (2)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 5;
    });
    expect((await db.query('SELECT probe()+1')).rows, [
      [BigInt.from(6)]
    ]);
    expect(calls, 1);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY); '
        'INSERT INTO t VALUES (1), (2);';
    for (final sql in [
      'SELECT 1+2 AS s, 8/2 AS d, 3*4 AS p',
      'SELECT id FROM t WHERE 1=0',
      'SELECT id FROM t WHERE 1=1 ORDER BY id',
      'SELECT id FROM t WHERE id = 1+1 ORDER BY id',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('plain aggregates stream without changing results', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT, b INT)');
    await db.execute(
        'INSERT INTO t VALUES (1, 1), (1, NULL), (2, 4), (2, 6), (3, NULL)');
    var calls = 0;
    db.functions.registerScalar('probe', 1, (args) {
      calls++;
      return args.single;
    });
    expect((await db.query('SELECT sum(probe(b)) FROM t')).rows.single.single,
        BigInt.from(11));
    expect(calls, 5);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(a INT, b INT); '
        'INSERT INTO t VALUES (1, 1), (1, NULL), (2, 4), (2, 6), (3, NULL);';
    for (final sql in [
      'SELECT count(*), count(b), sum(b), min(b), max(b), avg(b) FROM t',
      'SELECT count(*) FROM t WHERE 0',
      'SELECT a, count(b) AS n, sum(b) AS s FROM t GROUP BY a ORDER BY a',
      'SELECT a, count(*) AS n FROM t GROUP BY a HAVING count(*) > 1 ORDER BY a',
      "SELECT group_concat(b, ',') AS g FROM t",
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect(actual.rows.length, expected.length, reason: sql);
      for (var i = 0; i < actual.rows.length; i++) {
        final left = [
          for (final value in actual.rows[i])
            value is BigInt ? value.toInt() : value
        ];
        final right = (expected[i] as Map).values.toList();
        expect(left.length, right.length, reason: sql);
        for (var c = 0; c < left.length; c++) {
          final l = left[c];
          final r = right[c];
          if (l is double && r is num) {
            expect(l, closeTo(r.toDouble(), 1e-9), reason: sql);
          } else {
            expect(l, r, reason: sql);
          }
        }
      }
    }
  });

  test('identical scalar subqueries are reused and probe stays separate',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES (1), (2), (3)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 7;
    });
    expect(
        (await db.query(
                'SELECT (SELECT count(*) FROM t) AS a, (SELECT count(*) FROM t) AS b'))
            .rows,
        [
          [BigInt.from(3), BigInt.from(3)]
        ]);
    calls = 0;
    await db.query('SELECT probe(), probe()');
    expect(calls, 2);
    calls = 0;
    expect(
        (await db.query(
                'SELECT (SELECT probe() FROM t LIMIT 1) AS a, (SELECT probe() FROM t LIMIT 1) AS b'))
            .rows,
        [
          [BigInt.from(7), BigInt.from(7)]
        ]);
    expect(calls, 2);
    final values = [for (var i = 1; i <= 4000; i++) '($i)'].join(',');
    await db.execute('CREATE TABLE wide(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO wide VALUES $values');
    await db.execute('CREATE TABLE other(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO other VALUES $values');
    final image = db.exportImage();
    final same = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(same.close);
    final beforeSame = same.pagesRead;
    await same.query(
        'SELECT (SELECT count(*) FROM wide) AS a, (SELECT count(*) FROM wide) AS b');
    final samePages = same.pagesRead - beforeSame;
    final different =
        await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(different.close);
    final beforeDifferent = different.pagesRead;
    await different.query(
        'SELECT (SELECT count(*) FROM wide) AS a, (SELECT count(*) FROM other) AS b');
    expect(samePages, lessThan(different.pagesRead - beforeDifferent));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY); '
        'INSERT INTO t VALUES (1), (2), (3);';
    const sql =
        'SELECT (SELECT count(*) FROM t) AS a, (SELECT count(*) FROM t) AS b';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query(sql);
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in jsonDecode(native.stdout.toString()) as List)
        (row as Map).values.toList()
    ]);
  });

  test('unordered LIMIT stops a table scan', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, b INT)');
    final values = [for (var i = 1; i <= 4000; i++) '($i, ${i % 7})'].join(',');
    await db.execute('INSERT INTO t VALUES $values');
    final image = db.exportImage();
    final stopped = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(stopped.close);
    final before = stopped.pagesRead;
    expect((await stopped.query('SELECT id FROM t LIMIT 3')).rows, [
      [BigInt.one],
      [BigInt.two],
      [BigInt.from(3)]
    ]);
    final limitedPages = stopped.pagesRead - before;
    final full = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(full.close);
    final beforeFull = full.pagesRead;
    await full.query('SELECT count(*) FROM t');
    expect(limitedPages, lessThan(full.pagesRead - beforeFull));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, b INT); '
        'INSERT INTO t VALUES $values;';
    for (final sql in [
      'SELECT id FROM t LIMIT 3',
      'SELECT id FROM t LIMIT 2 OFFSET 2',
      'SELECT id FROM t WHERE id > 10 LIMIT 3',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('an unused derived column can be dropped and a function stays',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b INT)');
    final values =
        [for (var i = 1; i <= 8; i++) '($i, $i, ${i * 10})'].join(',');
    await db.execute('INSERT INTO t VALUES $values');
    var calls = 0;
    db.functions.registerScalar('probe', 1, (args) {
      calls++;
      return args[0];
    });
    final probed = await db.query(
        'SELECT a FROM (SELECT probe(b) AS p, a, b FROM t LIMIT 5) d WHERE a > 0 ORDER BY a');
    expect(calls, 5);
    expect(probed.rows, [
      for (var i = 1; i <= 5; i++) [BigInt.from(i)]
    ]);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b INT); '
        'INSERT INTO t VALUES $values;';
    for (final sql in [
      'SELECT a FROM (SELECT a, b FROM t LIMIT 5) d WHERE a > 2 ORDER BY a',
      'SELECT a FROM (SELECT a, b FROM t LIMIT 5) d WHERE a > 0 ORDER BY a',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('a contradictory filter matches SQLite without a scan', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT)');
    final values = [for (var i = 1; i <= 4000; i++) '($i, $i)'].join(',');
    await db.execute('INSERT INTO t VALUES $values');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 1;
    });
    await db.query('SELECT id FROM t WHERE probe() AND a > 1 AND a < 1');
    expect(calls, 4000);
    final image = db.exportImage();
    final stopped = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(stopped.close);
    final before = stopped.pagesRead;
    expect((await stopped.query('SELECT id FROM t WHERE a > 1 AND a < 1')).rows,
        isEmpty);
    final skippedPages = stopped.pagesRead - before;
    final full = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(full.close);
    final beforeFull = full.pagesRead;
    await full.query('SELECT count(*) FROM t');
    expect(skippedPages, lessThan(full.pagesRead - beforeFull));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT); '
        'INSERT INTO t VALUES $values;';
    for (final sql in [
      'SELECT id FROM t WHERE a > 1 AND a < 1',
      'SELECT count(*) AS n FROM t WHERE a > 1 AND a < 1',
      'SELECT id FROM t WHERE (a > 1 AND a < 1) OR id = 2',
      'SELECT id FROM t WHERE a >= 1 AND a <= 1 ORDER BY id',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('MIN and MAX of an integer primary key read one end', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, b INT)');
    await db.execute('CREATE TABLE empty(id INTEGER PRIMARY KEY)');
    final values = [for (var i = 1; i <= 4000; i++) '($i, ${i % 7})'].join(',');
    await db.execute('INSERT INTO t(id, b) VALUES $values');
    await db.execute('DELETE FROM t WHERE id = 1');
    final image = db.exportImage();
    final stopped = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(stopped.close);
    final before = stopped.pagesRead;
    expect((await stopped.query('SELECT MAX(id) FROM t')).rows, [
      [BigInt.from(4000)]
    ]);
    final extremePages = stopped.pagesRead - before;
    final full = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(full.close);
    final beforeFull = full.pagesRead;
    await full.query('SELECT count(*) FROM t');
    expect(extremePages, lessThan(full.pagesRead - beforeFull));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, b INT); '
        'CREATE TABLE empty(id INTEGER PRIMARY KEY); '
        'INSERT INTO t(id, b) VALUES $values; '
        'DELETE FROM t WHERE id = 1;';
    for (final sql in [
      'SELECT MIN(id) FROM t',
      'SELECT MAX(id) FROM t',
      'SELECT MIN(id) FROM empty',
      'SELECT MAX(id) FROM empty',
      'SELECT MIN(id) FROM t WHERE id > 10',
      'SELECT MIN(b) FROM t',
      'SELECT count(*) FROM t',
      'SELECT count(*) FROM empty',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('ordered DISTINCT and GROUP BY keep SQLite rows', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT, b INT)');
    await db.execute('CREATE INDEX ia ON t(a, b)');
    await db.execute(
        'INSERT INTO t VALUES (1, 1), (1, 1), (NULL, 1), (NULL, NULL), (2, 1), (1, 2)');
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(a INT, b INT); '
        'CREATE INDEX ia ON t(a, b); '
        'INSERT INTO t VALUES (1, 1), (1, 1), (NULL, 1), (NULL, NULL), (2, 1), (1, 2);';
    for (final sql in [
      'SELECT DISTINCT a FROM t ORDER BY a',
      'SELECT DISTINCT a, b FROM t ORDER BY a, b',
      'SELECT a, count(*) AS n FROM t GROUP BY a ORDER BY a',
      'SELECT a, b, count(*) AS n FROM t GROUP BY a, b ORDER BY a, b',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('a repeated CTE is shared unless NOT MATERIALIZED', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES (1), (2), (3)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 1;
    });
    Future<void> once(String sql, int expected) async {
      calls = 0;
      await db.query(sql);
      expect(calls, expected, reason: sql);
    }

    await once(
        'WITH c(v) AS (SELECT probe()) SELECT v FROM c UNION ALL SELECT v FROM c',
        1);
    await once(
        'WITH c(v) AS MATERIALIZED (SELECT probe()) SELECT v FROM c WHERE v = 1',
        1);
    await once(
        'WITH c(v) AS NOT MATERIALIZED (SELECT probe()) '
        'SELECT v FROM c UNION ALL SELECT v FROM c',
        2);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY); '
        'INSERT INTO t VALUES (1), (2), (3);';
    for (final sql in [
      'WITH c(v) AS (SELECT id FROM t) SELECT v FROM c WHERE v > 1 ORDER BY v',
      'WITH c(v) AS MATERIALIZED (SELECT id FROM t) '
          'SELECT v FROM c WHERE v > 1 ORDER BY v',
      'WITH c(v) AS NOT MATERIALIZED (SELECT id FROM t) '
          'SELECT v FROM c UNION ALL SELECT v FROM c ORDER BY v',
      'SELECT v FROM (SELECT id AS v FROM t LIMIT 1) AS d WHERE v = 2',
    ]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final text = native.stdout.toString().trim();
      final expected = text.isEmpty ? const [] : jsonDecode(text) as List;
      expect([
        for (final row in actual.rows)
          [for (final value in row) value is BigInt ? value.toInt() : value]
      ], [
        for (final row in expected) (row as Map).values.toList()
      ], reason: sql);
    }
  });

  test('a correlated subquery stays tied to the outer row', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE b(v INT)');
    await db.execute('INSERT INTO a VALUES (1), (2), (3)');
    await db.execute('INSERT INTO b VALUES (1), (2), (3)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 1;
    });
    const probed =
        'SELECT a.id AS aid, (SELECT b.v FROM b WHERE b.v = a.id AND probe() = 1) AS v '
        'FROM a ORDER BY aid';
    expect((await db.query(probed)).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two],
      [BigInt.from(3), BigInt.from(3)]
    ]);
    expect(calls, 3);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const plain =
        'SELECT a.id AS aid, (SELECT b.v FROM b WHERE b.v = a.id) AS v FROM a ORDER BY aid';
    const setup = 'CREATE TABLE a(id INTEGER PRIMARY KEY); '
        'CREATE TABLE b(v INT); '
        'INSERT INTO a VALUES (1), (2), (3); '
        'INSERT INTO b VALUES (1), (2), (3);';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $plain;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query(plain);
    final expected = jsonDecode(native.stdout.toString()) as List;
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in expected) (row as Map).values.toList()
    ]);
  });

  test('an inner lookup stops after 1024 distinct keys', () async {
    Future<void> check(int rows, String planText) async {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, k INT)');
      await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY, k INT)');
      await db.execute('CREATE INDEX bk ON b(k)');
      await db.execute('INSERT INTO a VALUES (1, 1), (2, $rows)');
      final values = [for (var i = 1; i <= rows; i++) '($i, $i)'].join(',');
      await db.execute('INSERT INTO b(id, k) VALUES $values');
      await db.execute('ANALYZE');
      const query =
          'SELECT a.id AS aid, b.id AS bid FROM a INNER JOIN b ON a.k = b.k '
          'ORDER BY aid, bid';
      final plan = await db.query('EXPLAIN QUERY PLAN $query');
      expect(plan.rows.last[3].toString(), planText, reason: '$rows keys');
      const pinned = '/tmp/sqlite-build/sqlite3';
      if (!File(pinned).existsSync()) return;
      final setup = 'CREATE TABLE a(id INTEGER PRIMARY KEY, k INT); '
          'CREATE TABLE b(id INTEGER PRIMARY KEY, k INT); '
          'CREATE INDEX bk ON b(k); '
          'INSERT INTO a VALUES (1, 1), (2, $rows); '
          'INSERT INTO b(id, k) VALUES $values;';
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $query;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(query);
      final expected = jsonDecode(native.stdout.toString()) as List;
      expect(actual.rows.length, expected.length, reason: '$rows keys');
      for (var i = 0; i < actual.rows.length; i++) {
        expect([
          for (final value in actual.rows[i])
            value is BigInt ? value.toInt() : value
        ], (expected[i] as Map).values.toList(), reason: '$rows keys row $i');
      }
    }

    await check(1024, 'SEARCH b USING INDEX bk (k=?)');
    await check(1025, 'SCAN b');
  });

  test('unordered joins keep nested-loop order', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db.execute('INSERT INTO a VALUES (1, 2), (2, 1), (3, 2)');
    await db.execute('INSERT INTO b VALUES (1, 1), (2, 2), (3, 2)');
    const indexed =
        'SELECT a.id AS aid, b.id AS bid FROM a INNER JOIN b ON a.k = b.k';
    const filtered =
        'SELECT a.id AS aid, b.id AS bid FROM a, b WHERE a.k = b.k';
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE a(id INTEGER PRIMARY KEY, k INT); '
        'CREATE TABLE b(id INTEGER PRIMARY KEY, k INT); '
        'CREATE INDEX bk ON b(k); '
        'INSERT INTO a VALUES (1, 2), (2, 1), (3, 2); '
        'INSERT INTO b VALUES (1, 1), (2, 2), (3, 2);';
    for (final sql in [indexed, filtered]) {
      final native =
          await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final actual = await db.query(sql);
      final expected = jsonDecode(native.stdout.toString()) as List;
      expect(actual.rows.length, expected.length, reason: sql);
      for (var i = 0; i < actual.rows.length; i++) {
        expect([
          for (final value in actual.rows[i])
            value is BigInt ? value.toInt() : value
        ], (expected[i] as Map).values.toList(), reason: '$sql row $i');
      }
    }
  });

  test('diagnosis shows an index seek, a join search, and one-end MIN',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT)');
    await db.execute('CREATE INDEX ia ON t(a)');
    await db.execute('CREATE TABLE u(id INTEGER PRIMARY KEY, k INT)');
    await db.execute('CREATE INDEX uk ON u(k)');
    await db.execute('INSERT INTO t VALUES (1, 10), (2, 20)');
    await db.execute('INSERT INTO u VALUES (1, 10), (2, 10)');
    final reader =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    addTearDown(reader.close);
    final seek = await reader.diagnoseQuery('SELECT id FROM t WHERE a = 10');
    expect(seek.plan.access, 'secondary-index-lookup');
    expect(seek.plan.indexName, 'ia');
    expect(seek.result.rows, [
      [BigInt.one]
    ]);
    final extreme = await reader.diagnoseQuery('SELECT MAX(id) FROM t');
    expect(
        extreme.decisions.any((decision) =>
            decision.access == 'primary-key-extreme' &&
            decision.reason == 'max'),
        isTrue);
    expect(extreme.result.rows, [
      [BigInt.two]
    ]);
    final join = await reader
        .diagnoseQuery('SELECT t.id AS tid FROM t INNER JOIN u ON t.a = u.k');
    expect(join.plan.access, 'inner-join-search');
    expect(
        join.decisions.any((decision) =>
            decision.access == 'inner-join-search' &&
            decision.reason.contains('SEARCH u')),
        isTrue);
    expect(join.result.rows.length, 2);
  });

  test('a later ANALYZE changes the next plan', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b INT)');
    await db.execute('CREATE INDEX ia ON t(a)');
    await db.execute('INSERT INTO t VALUES ${[
      for (var i = 1; i <= 20; i++) '($i, 1, $i)'
    ].join(',')}');
    const sql = 'SELECT b FROM t WHERE a = 1';
    final before = await db.query('EXPLAIN QUERY PLAN $sql');
    expect(before.rows.single[3].toString(), contains('INDEX ia'));
    await db.execute('ANALYZE');
    final after = await db.query('EXPLAIN QUERY PLAN $sql');
    expect(after.rows.single[3].toString(), contains('SCAN t'));
    expect(after.rows.single[3].toString(),
        isNot(before.rows.single[3].toString()));
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b INT); '
        'CREATE INDEX ia ON t(a); '
        'INSERT INTO t VALUES ${[
      for (var i = 1; i <= 20; i++) '($i, 1, $i)'
    ].join(',')}; '
        'ANALYZE;';
    final native = await Process.run(pinned, [
      '-json',
      ':memory:',
      '$setup SELECT b FROM t WHERE a = 1 ORDER BY b;'
    ]);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query('$sql ORDER BY b');
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in jsonDecode(native.stdout.toString()) as List)
        (row as Map).values.toList()
    ]);
  });

  test('a bound parameter still uses the index', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT)');
    await db.execute('CREATE INDEX ia ON t(a)');
    await db.execute('INSERT INTO t VALUES (1, 1), (2, 2), (3, 2), (4, 4)');
    final reader =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    addTearDown(reader.close);
    final plan = reader.explain('SELECT id FROM t WHERE a = ?', [BigInt.two]);
    expect(plan.access, 'secondary-index-lookup');
    expect(plan.indexName, 'ia');
    expect(
        (await reader.query(
                'SELECT id FROM t WHERE a = ? ORDER BY id', [BigInt.two]))
            .rows,
        [
          [BigInt.two],
          [BigInt.from(3)]
        ]);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    const setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT); '
        'CREATE INDEX ia ON t(a); '
        'INSERT INTO t VALUES (1, 1), (2, 2), (3, 2), (4, 4);';
    const sql = 'SELECT id FROM t WHERE a = 2 ORDER BY id';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await reader
        .query('SELECT id FROM t WHERE a = ? ORDER BY id', [BigInt.two]);
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in jsonDecode(native.stdout.toString()) as List)
        (row as Map).values.toList()
    ]);
  });

  test('IN lists above 32 and five-table joins keep their bounds', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INT)');
    await db.execute('CREATE INDEX ia ON t(a)');
    await db.execute('INSERT INTO t VALUES ${[
      for (var i = 1; i <= 40; i++) '($i, $i)'
    ].join(',')}');
    String list(int n) => [for (var i = 1; i <= n; i++) '$i'].join(',');
    final seek = await db
        .query('EXPLAIN QUERY PLAN SELECT id FROM t WHERE a IN (${list(32)})');
    expect(seek.rows.single[3].toString(), contains('INDEX ia'));
    final wide = await db
        .query('EXPLAIN QUERY PLAN SELECT id FROM t WHERE a IN (${list(33)})');
    expect(wide.rows.single[3].toString(), isNot(contains('INDEX ia')));
    await db.execute('CREATE TABLE a(v INT)');
    await db.execute('CREATE TABLE b(v INT)');
    await db.execute('CREATE TABLE c(v INT)');
    await db.execute('CREATE TABLE d(v INT)');
    await db.execute('CREATE TABLE e(v INT)');
    await db.execute('INSERT INTO a VALUES (1),(2),(3),(4),(5)');
    await db.execute('INSERT INTO b VALUES (1),(2),(3),(4)');
    await db.execute('INSERT INTO c VALUES (1),(2),(3)');
    await db.execute('INSERT INTO d VALUES (1)');
    await db.execute('INSERT INTO e VALUES (1),(2)');
    await db.execute('ANALYZE');
    final four = await db.query(
        'EXPLAIN QUERY PLAN SELECT a.v,b.v,c.v,d.v FROM a, b, c, d ORDER BY a.v');
    expect(four.rows.first[3].toString(), 'SCAN d');
    final five = await db.query(
        'EXPLAIN QUERY PLAN SELECT a.v,b.v,c.v,d.v,e.v FROM a, b, c, d, e ORDER BY a.v');
    expect([for (final row in five.rows) row[3].toString()],
        ['SCAN a', 'SCAN b', 'SCAN c', 'SCAN d', 'SCAN e']);
    const pinned = '/tmp/sqlite-build/sqlite3';
    if (!File(pinned).existsSync()) return;
    final setup = 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT); '
        'CREATE INDEX ia ON t(a); '
        'INSERT INTO t VALUES ${[
      for (var i = 1; i <= 40; i++) '($i, $i)'
    ].join(',')};';
    final sql = 'SELECT id FROM t WHERE a IN (${list(33)}) ORDER BY id';
    final native =
        await Process.run(pinned, ['-json', ':memory:', '$setup $sql;']);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final actual = await db.query(sql);
    expect([
      for (final row in actual.rows)
        [for (final value in row) value is BigInt ? value.toInt() : value]
    ], [
      for (final row in jsonDecode(native.stdout.toString()) as List)
        (row as Map).values.toList()
    ]);
  });

  test('malformed UTF-8 and UTF-16 records are rejected', () {
    expect(
        () =>
            RecordCodec.decode(Uint8List.fromList([2, 15, 0xFF]), encoding: 1),
        throwsFormatException);
    expect(
        () => RecordCodec.decode(Uint8List.fromList([2, 17, 0x00, 0xD8]),
            encoding: 2),
        throwsFormatException);
    expect(
        () =>
            RecordCodec.decode(Uint8List.fromList([2, 15, 0x41]), encoding: 2),
        throwsFormatException);
  });
}
