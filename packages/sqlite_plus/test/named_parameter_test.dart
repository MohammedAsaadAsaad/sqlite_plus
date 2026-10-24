import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('named parameters reuse indices and distinguish prefix and case',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect(
        (await db.query('SELECT :x,?1,:X,@x,\$x,:x,?', [1, 2, 3, 4, 5])).rows, [
      [
        BigInt.one,
        BigInt.one,
        BigInt.two,
        BigInt.from(3),
        BigInt.from(4),
        BigInt.one,
        BigInt.from(5)
      ]
    ]);
    expect((await db.query('SELECT ?3,:x,?1,:x,?', [1, 2, 3, 4, 5])).rows, [
      [
        BigInt.from(3),
        BigInt.from(4),
        BigInt.one,
        BigInt.from(4),
        BigInt.from(5)
      ]
    ]);
    expect(
        (await db.query(
                'SELECT \$namespace::value(suffix),\$namespace::value(suffix)',
                ['λ😀']))
            .rows,
        [
          ['λ😀', 'λ😀']
        ]);
    expect(
        (await db.query(
                'WITH c(x) AS(VALUES(:x)) SELECT x,:x,@x FROM c', [7, 8]))
            .rows,
        [
          [BigInt.from(7), BigInt.from(7), BigInt.from(8)]
        ]);
  });

  test('named indices span INSERT SELECT, UPSERT, RETURNING and CTAS',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v INT)');
    await db.execute('INSERT INTO t VALUES(:id,:v)', [1, 7]);
    final result = await db.execute(
        'INSERT INTO t SELECT :id,:v '
        'ON CONFLICT(id) DO UPDATE SET v=:v+1 RETURNING :id,:v,v',
        [1, 8]);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(8), BigInt.from(9)]
    ]);
    await db.execute('CREATE TABLE copied AS SELECT :value AS x', [12]);
    expect((await db.query('SELECT * FROM copied')).rows, [
      [BigInt.from(12)]
    ]);
    await db.execute('UPDATE t SET v=@v WHERE id=@id', [10, 1]);
    expect(
        (await db.execute('DELETE FROM t WHERE id=\$id RETURNING \$id,v', [1]))
            .returning!
            .rows,
        [
          [BigInt.one, BigInt.from(10)]
        ]);
  });

  test('variable index boundary and schema parameter restrictions', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final params = List<Object?>.filled(32766, null)..[32765] = 7;
    expect((await db.query('SELECT ?32766', params)).rows, [
      [BigInt.from(7)]
    ]);
    for (final sql in [
      'SELECT ?32767',
      'SELECT ?32766,:x',
      'SELECT :',
      'SELECT \$x(unclosed',
      'SELECT \$x(foo bar)',
      'SELECT :x'
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()));
    }
    final image = db.exportImage();
    for (final sql in [
      'CREATE TABLE bad(x CHECK(x>:v))',
      'CREATE TABLE bad(x DEFAULT(:v))',
      'CREATE TABLE bad(x,y AS(x+:v))',
      'CREATE VIEW bad AS SELECT :v'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), image);
    }
  });
}
