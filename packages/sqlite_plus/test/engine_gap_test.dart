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

  test(
      'qualified names resolve conflicts and one statement stays in one schema',
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
    await expectLater(db.execute("UPDATE main.t SET v=(SELECT v FROM temp.t)"),
        throwsA(isA<SqlException>()));
    expect((await db.query('SELECT v FROM main.t')).rows, [
      ['main']
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

  test('journal_mode reports the header and rejects unimplemented modes',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    expect(
        (await db.query('PRAGMA journal_mode')).rows.single.single, 'rollback');
    expect(sqlJournalMode(before[18]), 'rollback');
    await db.execute('PRAGMA journal_mode=rollback');
    expect(db.exportImage(), before);
    for (final mode in [
      'memory',
      'off',
      'delete',
      'persist',
      'truncate',
      'wal'
    ]) {
      await expectLater(db.execute('PRAGMA journal_mode=$mode'),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
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

  test('auto_vacuum stays rejected and is not read as success', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    expect(
        (await db.query('PRAGMA auto_vacuum')).rows.single.single, BigInt.zero);
    await expectLater(
        db.execute('PRAGMA auto_vacuum=1'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    final vacuum = Uint8List.fromList(before);
    ByteData.sublistView(vacuum).setUint32(52, 2);
    await expectLater(
        MutableSqliteDatabase.fromImage(vacuum), throwsUnsupportedError);
    await expectLater(
        ReadOnlyPager.open(ByteImageStorage(vacuum)), throwsUnsupportedError);
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
    await expectLater(
        db.query('EXPLAIN SELECT * FROM t'), throwsA(isA<SqlException>()));
    final plan = await db.query('EXPLAIN QUERY PLAN SELECT * FROM t');
    expect(plan.columns, ['detail']);
    expect(plan.rows.single.single.toString(), contains('t'));
    expect(plan.rows.single.single.toString(), isNot(contains('Opcode')));
  });

  test('sqlite_stat4 is rejected instead of being ignored', () async {
    final image = DatabaseImageBuilder.build(DatabaseImageBuilder.empty(), [
      ImageObject('table', 'sqlite_stat4', 'sqlite_stat4',
          'CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)')
    ]);
    await expectLater(
        MutableSqliteDatabase.fromImage(image), throwsA(isA<SqlException>()));
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
    expect(plan.rows.first.first.toString(), contains('small'));
    expect(plan.rows.last.first.toString(), contains('big'));
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
    expect(plan.rows.single.single.toString(), contains('COVERING'));
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
