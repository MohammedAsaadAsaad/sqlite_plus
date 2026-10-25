import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create();
    await db.execute('CREATE TABLE a(x INT,y TEXT COLLATE NOCASE)');
    await db.execute('CREATE TABLE b(x INT,y TEXT)');
    await db.execute('CREATE TABLE c(x INT,y TEXT)');
    await db.execute("INSERT INTO a VALUES(1,'a'),(2,'b')");
    await db.execute("INSERT INTO b VALUES(2,'A'),(3,'B')");
    await db.execute("INSERT INTO c VALUES(1,'c'),(2,'d')");
  });
  tearDown(() => db.close());

  test('JOIN ON resolves projection aliases for every join direction',
      () async {
    for (final join in ['JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN']) {
      final result = await db
          .query('SELECT a.x+1 AS q,b.x FROM a $join b ON q=b.x ORDER BY 1,2');
      expect(
          result.rows,
          [
            [BigInt.two, BigInt.two],
            [BigInt.from(3), BigInt.from(3)]
          ],
          reason: join);
    }
    expect(
        (await db.query('SELECT a.y AS q FROM a JOIN b ON q=b.y ORDER BY 1'))
            .rows,
        [
          ['a'],
          ['b']
        ]);
    expect(
        (await db.query(
                "SELECT a.y COLLATE NOCASE AS q FROM a JOIN b ON q=b.y ORDER BY 1"))
            .rows,
        [
          ['a'],
          ['b']
        ]);
  });

  test(
      'ON alias preparation rejects aggregates windows recursion and ambiguity',
      () async {
    for (final query in [
      'SELECT sum(a.x) AS q FROM a JOIN b ON q=b.x',
      'SELECT row_number() OVER() AS q FROM a JOIN b ON q=b.x',
      'SELECT a.x+1 AS q,q+1 AS r FROM a JOIN b ON r=b.x',
      'SELECT a.x+100 AS y FROM a JOIN b ON y=b.y',
      'SELECT a.x AS q FROM a JOIN b ON x=1 JOIN c',
      'SELECT a.x AS q FROM a JOIN b ON q=1 JOIN c ON missing=2',
    ]) {
      await expectLater(db.query(query), throwsA(isA<SqlException>()),
          reason: query);
    }
    await db.execute('CREATE TABLE only_value(q INT)');
    await db.execute('INSERT INTO only_value VALUES(2)');
    expect(
        (await db.query(
                'SELECT a.x+100 AS q FROM a JOIN only_value ON q=a.x ORDER BY 1'))
            .rows,
        [
          [BigInt.from(102)]
        ]);
  });

  test('ON alias expressions run lazily and independently of projection',
      () async {
    var calls = 0;
    db.functions.registerScalar('probe', 1, (arguments) {
      calls++;
      return arguments.single;
    });
    expect(
        (await db.query('SELECT probe(a.x) AS q FROM a JOIN b ON 0 AND q=b.x'))
            .rows,
        isEmpty);
    expect(calls, 0);
    await db.query('SELECT probe(a.x) AS q FROM a JOIN b ON q=b.x');
    expect(calls, greaterThan(0));
    calls = 0;
    await db.query('SELECT probe(a.x) AS q FROM a JOIN b ON a.x=0 AND q=b.x');
    expect(calls, 0);
  });

  test('INNER and CROSS ON can refer to later sources', () async {
    for (final join in ['JOIN', 'CROSS JOIN']) {
      final result = await db.query('SELECT a.x,b.x,c.x FROM a $join b '
          'ON c.x=a.x JOIN c ORDER BY 1,2,3');
      expect(
          result.rows,
          [
            [1, 2, 1],
            [1, 3, 1],
            [2, 2, 2],
            [2, 3, 2]
          ].map((row) => row.map(BigInt.from).toList()).toList());
    }
    expect(
        (await db.query(
                'SELECT a.x+1 AS q FROM a JOIN b ON q=c.x JOIN c ORDER BY 1'))
            .rows,
        [
          [BigInt.two],
          [BigInt.two]
        ]);
  });

  test('forward inner conditions filter after a later LEFT join', () async {
    expect(
        (await db.query('SELECT a.x FROM a JOIN b ON c.x=a.x '
                'LEFT JOIN c ON c.x=999'))
            .rows,
        isEmpty);
    expect(
        (await db.query('SELECT a.x FROM a JOIN b ON c.x IS NULL '
                'LEFT JOIN c ON c.x=999 ORDER BY 1'))
            .rows,
        [
          [BigInt.one],
          [BigInt.one],
          [BigInt.two],
          [BigInt.two]
        ]);
    expect(
        (await db.query('SELECT a.x FROM a JOIN b ON c.x=a.x '
                'LEFT JOIN c ON c.x=1 ORDER BY 1'))
            .rows,
        [
          [BigInt.one],
          [BigInt.one]
        ]);
  });

  test('forward ON references reject on outer joins and across RIGHT FULL',
      () async {
    for (final query in [
      for (final join in ['LEFT', 'RIGHT', 'FULL'])
        'SELECT a.x FROM a $join JOIN b ON c.x=a.x JOIN c',
      for (final join in ['RIGHT', 'FULL'])
        'SELECT a.x FROM a JOIN b ON c.x=a.x $join JOIN c',
      'SELECT a.x FROM a LEFT JOIN b ON EXISTS(SELECT 1 WHERE c.x=a.x) JOIN c',
    ]) {
      await expectLater(db.query(query), throwsA(isA<SqlException>()),
          reason: query);
    }
  });

  test('literal-zero ON folding precedes column and alias binding', () async {
    for (final predicate in [
      '0 AND missing',
      'missing AND 0',
      '0 AND q=b.x',
      '(missing AND 0) OR 0'
    ]) {
      final result = await db.query('SELECT sum(a.x) AS q FROM a JOIN b '
          'ON $predicate');
      expect(
          result.rows,
          [
            [null]
          ],
          reason: predicate);
    }
    for (final predicate in [
      '0.0 AND missing',
      'FALSE AND missing',
      '-0 AND missing',
      'NULL AND missing',
      '1 OR missing',
      '0 AND sum(a.x)',
      '0 AND row_number() OVER()'
    ]) {
      await expectLater(db.query('SELECT a.x FROM a JOIN b ON $predicate'),
          throwsA(isA<SqlException>()),
          reason: predicate);
    }
  });
}
