import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class Recorder implements SqlAggregate {
  Recorder({this.onStep});
  final void Function()? onStep;
  final values = <Object?>[];
  @override
  void step(List<Object?> arguments) {
    values.add(arguments.isEmpty ? 'zero' : arguments.single);
    onStep?.call();
  }

  @override
  Object? finish() => values.map((v) => v?.toString() ?? 'NULL').join('|');
}

void main() {
  test('ordered custom aggregates retain DISTINCT collation and NULL values',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.functions.registerAggregate('collect', 1, Recorder.new);
    db.functions.registerAggregate('zero', 0, Recorder.new);
    expect(
        (await db.query(
                "WITH t(v,k) AS(VALUES('b',2),('a',1),('A',3),(NULL,0)) "
                "SELECT collect(v ORDER BY k DESC),collect(DISTINCT v COLLATE NOCASE ORDER BY v COLLATE NOCASE),zero() FROM t"))
            .rows,
        [
          ['A|b|a|NULL', 'NULL|A|b', 'zero|zero|zero|zero']
        ]);
  });

  test('unordered callbacks stream steps while ordered inputs materialize',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var steps = 0;
    db.functions.registerScalar('peek', 0, (args) => steps);
    db.functions
        .registerAggregate('collect', 1, () => Recorder(onStep: () => steps++));
    expect(
        (await db.query(
                'WITH t(x) AS(VALUES(1),(2),(3)) SELECT collect(peek()) FROM t'))
            .rows,
        [
          ['0|1|2']
        ]);
    steps = 0;
    expect(
        (await db.query(
                'WITH t(x) AS(VALUES(1),(2),(3)) SELECT collect(peek() ORDER BY x DESC) FROM t'))
            .rows,
        [
          ['0|0|0']
        ]);
  });

  test('STRING_AGG, FILTER and aggregate ordering restrictions', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute('INSERT INTO t VALUES(1),(2),(3)');
    expect(
        (await db.query(
                "SELECT string_agg(x,'|' ORDER BY x DESC) FILTER(WHERE x>1) FROM t"))
            .rows,
        [
          ['3|2']
        ]);
    expect(
        (await db.query(
                "SELECT string_agg(x,'|') OVER(ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t ORDER BY x"))
            .rows,
        [
          ['1'],
          ['1|2'],
          ['2|3']
        ]);
    for (final sql in [
      'SELECT abs(x ORDER BY x) FROM t',
      'SELECT sum(x ORDER BY x) OVER() FROM t',
      'SELECT sum(x ORDER BY count(*)) FROM t',
      'SELECT count(* ORDER BY x) FROM t'
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()));
    }
  });
}
