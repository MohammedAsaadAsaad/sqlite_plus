@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    for (final type in [
      'INT',
      'REAL',
      'TEXT COLLATE NOCASE',
      'TEXT COLLATE RTRIM',
      'BLOB'
    ]) {
      for (final direction in ['', 'DESC']) {
        test(
            'physical inner seek preserves SQL equality $type $direction $encoding',
            () async {
          final text = type.startsWith('TEXT');
          final blob = type == 'BLOB';
          final outer = text
              ? "(1,'A'),(2,'a'),(3,NULL),(4,'b '),(5,'z')"
              : blob
                  ? "(1,x'00ff'),(2,x'00ff'),(3,NULL),(4,x'01'),(5,x'ff')"
                  : "(1,2),(2,2.0),(3,NULL),(4,-1),(5,99)";
          final inner = text
              ? "(1,'a','one'),(2,'A','two'),(3,NULL,'null'),(4,'b','trim'),(5,'b ','space')"
              : blob
                  ? "(1,x'00ff','one'),(2,x'00ff','two'),(3,NULL,'null'),(4,x'01','last')"
                  : "(1,2,'one'),(2,2,'two'),(3,NULL,'null'),(4,-1,'last')";
          final statements = [
            'CREATE TABLE a(id INTEGER PRIMARY KEY,k $type)',
            'CREATE TABLE b(id INTEGER PRIMARY KEY,k $type,v TEXT)',
            'CREATE INDEX bk ON b(k $direction)',
            'INSERT INTO a VALUES $outer',
            'INSERT INTO b VALUES $inner',
          ];
          final db = await MutableSqliteDatabase.create(encoding: encoding);
          addTearDown(db.close);
          for (final sql in statements) {
            await db.execute(sql);
          }
          final ro = await SqliteDatabase.openReadOnly(
              ByteImageStorage(db.exportImage()));
          addTearDown(ro.close);
          for (final query in [
            'SELECT a.id AS aid,b.id AS bid,b.v FROM a INNER JOIN b ON a.k=b.k',
            'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON b.k=a.k AND b.id>1 ORDER BY aid,bid',
            'SELECT count(*) AS n FROM a INNER JOIN b ON a.k=b.k GROUP BY a.k HAVING count(*)>1 ORDER BY a.k',
            blob
                ? 'SELECT a.id AS aid,b.v FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id LIMIT 3 OFFSET 1'
                : 'SELECT a.*,b.v FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id LIMIT 3 OFFSET 1',
          ]) {
            final expected = await optimizerOracle(statements.join(';'), query);
            expect((await db.query(query)).rows, expected, reason: query);
            expect((await ro.query(query)).rows, expected, reason: query);
          }
          expect(
              ro
                  .describeQueryPlan(
                      'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k')
                  .last,
              'SEARCH b USING INDEX bk (k=?)');
          const boundSql =
              'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k WHERE b.id>? ORDER BY a.id,b.id';
          for (final bound in [0, 2, 100]) {
            final expected = await optimizerOracle(statements.join(';'),
                'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k WHERE b.id>$bound ORDER BY a.id,b.id');
            expect((await db.query(boundSql, [bound])).rows, expected);
            expect((await ro.query(boundSql, [bound])).rows, expected);
          }
        });
      }
    }
  }

  test(
      'sparse indexed join reads matching pages rather than the full inner table',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY,k INT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY,k INT,v TEXT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db
        .execute('INSERT INTO a VALUES(1,1),(2,3000),(3,1),(4,NULL),(5,9999)');
    for (var start = 1; start <= 3000; start += 500) {
      await db.execute('INSERT INTO b VALUES ${[
        for (var i = start; i < start + 500; i++) "($i,$i,'${'x' * 100}')"
      ].join(',')}');
    }
    await db.execute('ANALYZE');
    final image = db.exportImage();
    final indexed = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    final scan = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(indexed.close);
    addTearDown(scan.close);
    const sql =
        'SELECT a.id AS aid,b.id AS bid,b.v FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id';
    final beforeIndexed = indexed.pagesRead, beforeScan = scan.pagesRead;
    final actual = await indexed.query(sql);
    final expected = await scan
        .query(sql.replaceFirst('JOIN b ON', 'JOIN b NOT INDEXED ON'));
    final indexedReads = indexed.pagesRead - beforeIndexed,
        scanReads = scan.pagesRead - beforeScan;
    expect(actual.rows, expected.rows);
    expect(actual.rows.length, 3);
    expect(indexedReads, lessThan(scanReads ~/ 3),
        reason: 'index=$indexedReads scan=$scanReads');
    expect(
        indexed.describeQueryPlan(sql).last, 'SEARCH b USING INDEX bk (k=?)');
  });

  test(
      'fallbacks preserve complete inputs and distinguish temporary lookup plans',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const statements = [
      'CREATE TABLE a(id INTEGER PRIMARY KEY,k INT)',
      'CREATE TABLE b(id INTEGER PRIMARY KEY,k INT,v INT)',
      'CREATE INDEX bk ON b(k,v)',
      'INSERT INTO a VALUES(1,2),(2,NULL),(3,9)',
      'INSERT INTO b VALUES(1,2,1),(2,2,0),(3,NULL,9),(4,7,0)'
    ];
    for (final sql in statements) {
      await db.execute(sql);
    }
    for (final sql in [
      'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id',
      'SELECT a.id AS aid,b.id AS bid FROM a LEFT JOIN b ON a.k=b.k ORDER BY a.id,b.id',
      'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k OR a.id=b.id ORDER BY a.id,b.id',
      'SELECT a.id AS aid,b.id AS bid,(SELECT count(*) FROM b) AS n FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id',
      'WITH b AS (SELECT 1 AS id,2 AS k) SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id',
    ]) {
      expect((await db.query(sql)).rows,
          await optimizerOracle(statements.join(';'), sql),
          reason: sql);
    }
    expect(
        (await db.query(
                'EXPLAIN QUERY PLAN SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k'))
            .rows
            .last[3],
        'SEARCH b USING TEMPORARY LOOKUP (k=?)');
    await db.execute('DROP INDEX bk');
    await db.execute('CREATE INDEX bk ON b(k DESC)');
    var calls = 0;
    db.functions.registerScalar('probe', 1, (args) {
      calls++;
      return args.single;
    });
    const query =
        'SELECT probe(b.id) FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id';
    expect((await db.query(query)).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
    expect(calls, 2);
    expect((await db.query('EXPLAIN QUERY PLAN $query')).rows.last[3],
        'SEARCH b USING TEMPORARY LOOKUP (k=?)');
  });
  test(
      'join probes are per execution and explicit index collation mismatches fall back',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY,k TEXT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY,k TEXT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db.execute("INSERT INTO a VALUES(1,'A'),(2,'a')");
    await db.execute("INSERT INTO b VALUES(1,'A')");
    const query =
        'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id';
    expect((await db.query(query)).rows, [
      [BigInt.one, BigInt.one]
    ]);
    await db.execute("INSERT INTO b VALUES(2,'a')");
    expect((await db.query(query)).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two]
    ]);
    await db.execute('DROP INDEX bk');
    await db.execute('CREATE INDEX bk ON b(k COLLATE NOCASE)');
    expect((await db.query(query)).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two]
    ]);
    expect((await db.query('EXPLAIN QUERY PLAN $query')).rows.last[3],
        'SEARCH b USING TEMPORARY LOOKUP (k=?)');
  });
  test(
      'STAT1 density selects a scan without changing rows; forced index still seeks',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY,k INT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY,k INT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db.execute('INSERT INTO a VALUES(1,1),(2,NULL)');
    await db.execute('INSERT INTO b VALUES ${[
      for (var i = 1; i <= 16; i++) "($i,${i % 4})"
    ].join(',')}');
    await db.execute('ANALYZE');
    const query =
        'SELECT a.id AS aid,b.id AS bid FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id';
    expect((await db.query('EXPLAIN QUERY PLAN $query')).rows.last[3],
        'SEARCH b USING TEMPORARY LOOKUP (k=?)');
    final expected = (await db.query(query)).rows;
    final forced = query.replaceFirst('JOIN b ON', 'JOIN b INDEXED BY bk ON');
    expect((await db.query(forced)).rows, expected);
    expect((await db.query('EXPLAIN QUERY PLAN $forced')).rows.last[3],
        'SEARCH b USING INDEX bk (k=?)');
    await db.execute('DELETE FROM b');
    await db.execute('INSERT INTO b VALUES ${[
      for (var i = 1; i <= 20; i++) "($i,${i % 5})"
    ].join(',')}');
    await db.execute('ANALYZE');
    expect((await db.query('EXPLAIN QUERY PLAN $query')).rows.last[3],
        'SEARCH b USING INDEX bk (k=?)');
    expect(
        (await db.query(query)).rows,
        (await db.query(
                query.replaceFirst('JOIN b ON', 'JOIN b NOT INDEXED ON')))
            .rows);
  });
}
