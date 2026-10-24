import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class SumValues extends SqlAggregate {
  BigInt? total;
  @override
  void step(List<Object?> arguments) {
    for (final value in arguments) {
      if (value is BigInt) total = (total ?? BigInt.zero) + value;
    }
  }

  @override
  Object? finish() => total;
}

void main() {
  test('CURRENT keywords and dynamic defaults share the statement clock',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var serial = 0;
    db.functions.registerScalar('serial', 0, (args) => ++serial);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,stamp TEXT DEFAULT CURRENT_TIMESTAMP,n INT DEFAULT (serial()))');
    expect(serial, 0);
    await db.execute('INSERT INTO t(id) VALUES(1),(2)');
    final rows = (await db.query('SELECT stamp,n FROM t ORDER BY id')).rows;
    expect(rows[0][0], rows[1][0]);
    expect(rows.map((r) => r[1]), [BigInt.one, BigInt.two]);
    final time = (await db.query(
            'SELECT CURRENT_DATE,CURRENT_TIME,CURRENT_TIMESTAMP,date(),time(),datetime()'))
        .rows
        .single;
    expect(time.sublist(0, 3), time.sublist(3));
    expect(serial, 2);
    db.functions.registerScalar('date', 0, (args) => 'overridden');
    expect((await db.query('SELECT date()')).rows, [
      ['overridden']
    ]);
    expect((await db.query('SELECT CURRENT_DATE')).rows.single.single,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
  });
  test(
      'scalar overloads, varargs, built-in replacement and isolated connections',
      () async {
    final a = await MutableSqliteDatabase.create(),
        b = await MutableSqliteDatabase.create();
    addTearDown(a.close);
    addTearDown(b.close);
    a.functions.registerScalar('custom', 1, (args) => args.single);
    a.functions.registerScalar(
        'custom', 2, (args) => (args[0] as BigInt) + (args[1] as BigInt));
    a.functions.registerScalar('custom', -1, (args) => args.length);
    a.functions.registerScalar('length', 1, (args) => 42);
    expect(
        (await a.query(
                'SELECT custom(NULL),custom(2,3),custom(),length(\'x\')'))
            .rows,
        [
          [null, BigInt.from(5), BigInt.zero, BigInt.from(42)]
        ]);
    await expectLater(
        b.query('SELECT custom(1)'), throwsA(isA<SqlException>()));
    await expectLater(a.functions.run(() => b.query('SELECT custom(1)')),
        throwsA(isA<SqlException>()));
    expect((await b.query("SELECT length('x')")).rows, [
      [BigInt.one]
    ]);
    a.functions.unregister('custom', 1);
    expect((await a.query('SELECT custom(5)')).rows, [
      [BigInt.one]
    ]);
    a.functions.unregister('custom', -1);
    await expectLater(
        a.query('SELECT custom(1)'), throwsA(isA<SqlException>()));
  });
  test(
      'aggregates have independent group state, DISTINCT/FILTER and grouped windows',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.functions.registerAggregate('custom_sum', 1, SumValues.new);
    await db.execute('CREATE TABLE t(k,v)');
    await db.execute('INSERT INTO t VALUES(1,2),(1,2),(2,3),(2,NULL)');
    expect(
        (await db.query(
                'SELECT k,custom_sum(v),custom_sum(DISTINCT v),custom_sum(v) FILTER (WHERE v>2) FROM t GROUP BY k ORDER BY k'))
            .rows,
        [
          [BigInt.one, BigInt.from(4), BigInt.two, null],
          [BigInt.two, BigInt.from(3), BigInt.from(3), BigInt.from(3)]
        ]);
    expect((await db.query('SELECT custom_sum(v) FROM t WHERE 0')).rows, [
      [null]
    ]);
    expect(
        (await db.query(
                'SELECT k,sum(custom_sum(v)) OVER (ORDER BY k) FROM t GROUP BY k ORDER BY k'))
            .rows,
        [
          [BigInt.one, BigInt.from(4)],
          [BigInt.two, BigInt.from(7)]
        ]);
    await expectLater(db.query('SELECT custom_sum(v) OVER () FROM t'),
        throwsA(isA<SqlException>()));
  });
  test('callbacks protect blobs and failing values leave statements atomic',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.functions.registerScalar('copy', 1, (args) {
      final data = args.single as Uint8List;
      data[0] = 99;
      return data;
    });
    db.functions.registerScalar('bad', 0, (args) => Object());
    db.functions
        .registerScalar('explode', 0, (args) => throw StateError('failure'));
    db.functions.registerScalar(
        'valid', 1, (args) => (args.single as BigInt) > BigInt.zero ? 1 : 0);
    final bytes = Uint8List.fromList([1, 2]);
    expect((await db.query('SELECT copy(?)', [bytes])).rows, [
      [
        Uint8List.fromList([99, 2])
      ]
    ]);
    expect(bytes, [1, 2]);
    await db.execute('CREATE TABLE t(x CHECK(valid(x)))');
    await db.execute('INSERT INTO t VALUES(1)');
    final before = db.exportImage();
    for (final sql in [
      'INSERT INTO t VALUES(-1)',
      'INSERT INTO t VALUES(bad())',
      'INSERT INTO t VALUES(explode())'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    for (final arity in [-2, 1001]) {
      expect(() => db.functions.registerScalar('invalid', arity, (args) => 0),
          throwsArgumentError);
    }
  });
}
