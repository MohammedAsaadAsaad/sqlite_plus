import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async => db = await MutableSqliteDatabase.create());
  tearDown(() => db.close());

  Future<void> joinTables() async {
    await db.execute('CREATE TABLE a(x INT,ax INT)');
    await db.execute('CREATE TABLE b(x INT,bx INT)');
    await db.execute('CREATE TABLE c(x INT,cx INT)');
    await db.execute('INSERT INTO a VALUES(1,11),(2,12)');
    await db.execute('INSERT INTO b VALUES(1,21),(3,23)');
    await db.execute('INSERT INTO c VALUES(1,31),(3,33)');
  }

  test('a later independent column is ambiguous after USING or NATURAL',
      () async {
    await joinTables();
    for (final source in [
      'a JOIN b USING(x), c',
      'a NATURAL JOIN b JOIN c ON a.x=c.x',
      'a FULL JOIN b USING(x) JOIN c ON b.x=c.x',
      'a RIGHT JOIN b USING(x) CROSS JOIN c',
    ]) {
      for (final clause in [
        'SELECT x FROM $source',
        'SELECT a.x FROM $source WHERE x=1',
        'SELECT count(*) FROM $source GROUP BY x',
        'SELECT a.x AS resolved FROM $source ORDER BY x',
      ]) {
        await expectLater(db.query(clause), throwsA(isA<SqlException>()),
            reason: clause);
      }
    }
  });

  test('wildcards retain distinct merged groups beside independent columns',
      () async {
    await joinTables();
    final result = await db
        .query('SELECT * FROM a FULL JOIN b USING(x),c ORDER BY 1,2,3,4');
    expect(result.columns, ['x', 'ax', 'bx', 'x', 'cx']);
    expect(
        result.rows,
        [
          [1, 11, 21, 1, 31],
          [1, 11, 21, 3, 33],
          [2, 12, null, 1, 31],
          [2, 12, null, 3, 33],
          [3, null, 23, 1, 31],
          [3, null, 23, 3, 33],
        ]
            .map((row) =>
                row.map((v) => v == null ? null : BigInt.from(v)).toList())
            .toList());
  });

  test('a later USING combines only the first exposed left column', () async {
    await joinTables();
    final result =
        await db.query('SELECT * FROM a,b JOIN c USING(x) ORDER BY 1,2,3,4');
    expect(result.columns, ['x', 'ax', 'x', 'bx', 'cx']);
    expect(
        result.rows,
        [
          [1, 11, 1, 21, 31],
          [1, 11, 3, 23, 31],
        ].map((row) => row.map(BigInt.from).toList()).toList());
    for (final join in ['RIGHT', 'FULL']) {
      await expectLater(db.query('SELECT * FROM a,b $join JOIN c USING(x)'),
          throwsA(isA<SqlException>()));
    }
    await expectLater(db.query('SELECT x FROM a,b JOIN c USING(x)'),
        throwsA(isA<SqlException>()));
  });

  test('successive outer USING groups preserve qualified and merged values',
      () async {
    await joinTables();
    final result =
        await db.query('SELECT x,a.x,b.x,c.x FROM a FULL JOIN b USING(x) '
            'RIGHT JOIN c USING(x) ORDER BY 1');
    expect(result.rows, [
      [BigInt.one, BigInt.one, BigInt.one, BigInt.one],
      [BigInt.from(3), null, BigInt.from(3), BigInt.from(3)],
    ]);
  });

  test('quoted source aliases cannot collide with merged value slots',
      () async {
    await db.execute('CREATE TABLE a(x INT)');
    await db.execute('CREATE TABLE b(x INT)');
    await db.execute('INSERT INTO a VALUES(1)');
    await db.execute('INSERT INTO b VALUES(2)');
    final result = await db.query(
        'SELECT x,a.x,"@using1".x FROM a FULL JOIN b AS "@using1" USING(x) '
        'ORDER BY 1');
    expect(result.rows, [
      [BigInt.one, BigInt.one, null],
      [BigInt.two, null, BigInt.two],
    ]);
  });

  test('derived duplicate names are unique before rows are materialized',
      () async {
    for (final query in [
      'SELECT * FROM (SELECT 1 AS a,2 AS a)',
      'SELECT d.a,d."a:1" FROM (SELECT 1 AS a,2 AS a) d',
      'WITH t AS (SELECT 1 AS a,2 AS a) SELECT * FROM t',
      'WITH t(a,a) AS (SELECT 1,2) SELECT * FROM t',
    ]) {
      final result = await db.query(query);
      expect(result.columns, ['a', 'a:1'], reason: query);
      expect(
          result.rows,
          [
            [BigInt.one, BigInt.two]
          ],
          reason: query);
    }
  });

  test('deduplicated names preserve case and skip earlier suffix collisions',
      () async {
    final result = await db
        .query('SELECT * FROM (SELECT 1 AS a,2 AS A,3 AS "a:1",4 AS a)');
    expect(result.columns, ['a', 'A:1', 'a:2', 'a:3']);
    expect(result.rows, [
      [BigInt.one, BigInt.two, BigInt.from(3), BigInt.from(4)]
    ]);
  });

  test('view inferred and declared duplicate columns retain their positions',
      () async {
    for (final declaration in ['', '(a,a)']) {
      await db.execute('CREATE VIEW v$declaration AS SELECT 1 AS a,2 AS a');
      final result = await db.query('SELECT * FROM v');
      expect(result.columns, ['a', 'a:1']);
      expect(result.rows, [
        [BigInt.one, BigInt.two]
      ]);
      await db.execute('DROP VIEW v');
    }
  });

  test('deduplicated derived names participate in NATURAL joins separately',
      () async {
    final result = await db.query('SELECT * FROM (SELECT 1 AS a,2 AS a) '
        'NATURAL JOIN (SELECT 1 AS a,4 AS b)');
    expect(result.columns, ['a', 'a:1', 'b']);
    expect(result.rows, [
      [BigInt.one, BigInt.two, BigInt.from(4)]
    ]);
  });

  test('compound ORDER BY resolves aliases from each arm', () async {
    for (final operation in ['UNION', 'UNION ALL', 'INTERSECT', 'EXCEPT']) {
      final result = await db
          .query('SELECT 2 AS x $operation SELECT 1 AS y ORDER BY y DESC');
      final expected = switch (operation) {
        'INTERSECT' => <List<BigInt>>[],
        'EXCEPT' => [
            [BigInt.two]
          ],
        _ => [
            [BigInt.two],
            [BigInt.one]
          ],
      };
      expect(result.columns, ['x']);
      expect(result.rows, expected, reason: operation);
    }
    final result = await db.query("SELECT 'b' AS x UNION ALL SELECT 'A' AS y "
        'UNION ALL SELECT NULL AS z ORDER BY z COLLATE NOCASE NULLS LAST');
    expect(result.rows, [
      ['A'],
      ['b'],
      [null]
    ]);
  });

  test('compound left-arm aliases take precedence over later aliases',
      () async {
    final result = await db.query(
        'SELECT 1 AS a,2 AS b UNION ALL SELECT 3 AS b,4 AS a ORDER BY b DESC');
    expect(result.rows, [
      [BigInt.from(3), BigInt.from(4)],
      [BigInt.one, BigInt.two]
    ]);
    await expectLater(
        db.query('SELECT 2 AS x UNION SELECT 1 AS y ORDER BY y+0'),
        throwsA(isA<SqlException>()));
  });
}
