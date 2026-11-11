import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await openInMemory();
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>=0),name TEXT,b BLOB)');
    await db.execute("INSERT INTO t VALUES(1,10,'a',X'01'),(2,20,'b',X'02')");
  });
  tearDown(() async {
    await db.close();
  });
  test(
      'temp shadow routing invalidates; mutable boolean scopes are not retained',
      () async {
    final statement = await db.prepare('SELECT n FROM t WHERE id=?');
    expect((await statement.query([1])).rows.single.single, BigInt.from(10));
    await db.execute('CREATE TEMP TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO temp.t VALUES(1,77)');
    expect((await statement.query([1])).rows.single.single, BigInt.from(77));
    await db.execute('DROP TABLE temp.t');
    expect((await statement.query([1])).rows.single.single, BigInt.from(10));
    await statement.close();
    await expectLater(db.prepare('SELECT true FROM t'), throwsUnsupportedError);
    // Empty IN hides its operand in Expr.children; never retain that UDF node.
    db.functions.registerScalar('f', 1, (a) => a.single);
    await expectLater(
        db.prepare('SELECT f(n) IN () FROM t'), throwsUnsupportedError);
  });
  test('SELECT syntax reused with fresh bindings/data and binding-aware plans',
      () async {
    final stmt = await db.prepare(
        'SELECT id,n FROM t WHERE n>=? AND id>=? ORDER BY n DESC LIMIT ?');
    final parsed = stmt.expressionParseCount;
    expect((await stmt.query([10, 1, 1])).rows, [
      [BigInt.two, BigInt.from(20)]
    ]);
    expect((await stmt.query([10, 1, 2])).rows.length, 2);
    await db.execute('UPDATE t SET n=30 WHERE id=1');
    expect((await stmt.query([10, 1, 1])).rows, [
      [BigInt.one, BigInt.from(30)]
    ]);
    expect(stmt.selectParseCount, 1);
    expect(stmt.expressionParseCount, parsed);
    expect(stmt.preparationCount, 1);
    await stmt.close();
  });
  test(
      'DML reuses expression AST but constraints/counters/returning remain current',
      () async {
    final stmt =
        await db.prepare('UPDATE t SET n=? WHERE id=? AND n>=0 RETURNING id,n');
    final parsed = stmt.expressionParseCount;
    expect((await stmt.execute([11, 1])).returning!.rows, [
      [BigInt.one, BigInt.from(11)]
    ]);
    expect((await stmt.execute([21, 2])).changes, 1);
    expect(stmt.expressionParseCount, parsed);
    expect(stmt.expressionReuseCount, greaterThan(0));
    final before = db.exportImage();
    await expectLater(stmt.execute([-1, 1]), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect((await stmt.execute([12, 1])).changes, 1);
    expect((await db.query('SELECT changes()')).rows.single.single, BigInt.one);
    await stmt.close();
  });
  test('schema changes and rollback reprepare without stale columns or roots',
      () async {
    final stmt = await db.prepare('SELECT * FROM t WHERE id>=? ORDER BY id');
    expect((await stmt.query([1])).columns.length, 4);
    await db.execute('ALTER TABLE t ADD COLUMN extra TEXT');
    expect((await stmt.query([1])).columns.length, 5);
    expect(stmt.preparationCount, 2);
    await db.execute('BEGIN');
    await db.execute('UPDATE t SET n=99 WHERE id=1');
    expect((await stmt.query([1])).rows.first[1], BigInt.from(99));
    await db.execute('ROLLBACK');
    expect((await stmt.query([1])).rows.first[1], BigInt.from(10));
    expect(stmt.preparationCount, 3);
    await db.execute('DROP TABLE t');
    await expectLater(stmt.query([1]), throwsA(isA<SqlException>()));
    await stmt.close();
  });
  test('named/gapped params preserve binding slots; blobs copied per call',
      () async {
    final stmt =
        await db.prepare('SELECT :x,?3,:x FROM t WHERE id=:id LIMIT 1');
    expect(stmt.parameterCount, 4);
    expect((await stmt.query(['value', null, 7, 1])).rows, [
      ['value', BigInt.from(7), 'value']
    ]);
    expect((await stmt.query(['new', null, 8, 2])).rows, [
      ['new', BigInt.from(8), 'new']
    ]);
    await stmt.close();
    final insert =
        await db.prepare('INSERT INTO t(id,n,b) VALUES(?,?,?) RETURNING id');
    final bytes = Uint8List.fromList([3]);
    final pending = insert.execute([3, 3, bytes]);
    bytes[0] = 9;
    await pending;
    expect(
        (await db.query('SELECT b FROM t WHERE id=3')).rows.single.single, [3]);
    await insert.close();
  });
  test(
      'prepare has no data/callback side effects; changed functions rebind for DML',
      () async {
    var calls = 0;
    db.functions.registerScalar('f', 1, (a) {
      calls++;
      return a.single;
    });
    final before = db.exportImage();
    final stmt = await db.prepare('UPDATE t SET n=f(?) WHERE id=? RETURNING n');
    expect(calls, 0);
    expect(db.exportImage(), before);
    expect((await stmt.execute([7, 1])).returning!.rows.single.single,
        BigInt.from(7));
    db.functions
        .registerScalar('f', 1, (a) => (a.single as BigInt) + BigInt.one);
    expect((await stmt.execute([7, 1])).returning!.rows.single.single,
        BigInt.from(8));
    db.functions.unregister('f', 1);
    await expectLater(stmt.execute([7, 1]), throwsA(isA<SqlException>()));
    await stmt.close();
    await expectLater(db.prepare('SELECT f(n) FROM t'), throwsA(isA<Object>()));
  });
  test(
      'close, overlap, parameter bounds and unsupported preparation are explicit',
      () async {
    final stmt = await db.prepare('SELECT n FROM t WHERE id>=? ORDER BY id');
    final first = stmt.query([1]);
    await expectLater(stmt.query([2]), throwsStateError);
    await first;
    await expectLater(stmt.query([]), throwsA(isA<SqlException>()));
    await expectLater(stmt.execute([1]), throwsStateError);
    await stmt.close();
    await stmt.close();
    expect(stmt.isClosed, true);
    await expectLater(stmt.query([1]), throwsStateError);
    await expectLater(db.prepare('BEGIN'), throwsUnsupportedError);
    await expectLater(
        db.prepare('SELECT count(*) FROM t'), throwsUnsupportedError);
    await expectLater(
        db.prepare('SELECT missing FROM t'), throwsA(isA<SqlException>()));
    await expectLater(db.prepare('SELECT ?0'), throwsA(isA<SqlException>()));
  });
  test('IN/NULL/null-safe comparisons and casts do not retain prior values',
      () async {
    final stmt = await db
        .prepare('SELECT id FROM t WHERE name IS ? OR id IN (?,?) ORDER BY id');
    expect((await stmt.query(['a', 9, 10])).rows, [
      [BigInt.one]
    ]);
    expect((await stmt.query([null, 2, 10])).rows, [
      [BigInt.two]
    ]);
    expect((await stmt.query(['b', null, null])).rows, [
      [BigInt.two]
    ]);
    await stmt.close();
    final cast = await db.prepare('SELECT CAST(? AS INTEGER)+?');
    expect((await cast.query(['10', 2])).rows.single.single, BigInt.from(12));
    expect((await cast.query(['20', 3])).rows.single.single, BigInt.from(23));
    await cast.close();
  });
}
