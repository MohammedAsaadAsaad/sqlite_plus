import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create();
    await db.execute('CREATE TABLE t(a TEXT COLLATE NOCASE,b INT,c REAL,d)');
    await db.execute("INSERT INTO t VALUES('01',1,1,'A')");
  });
  tearDown(() => db.close());

  test('scalar subquery projections preserve affinity and declared types',
      () async {
    final result = await db.query('SELECT (SELECT a FROM t) AS a,'
        '(SELECT b FROM t) AS b,(SELECT c FROM t) AS c FROM t LIMIT 0');
    expect(result.columnAffinities, ['text', 'numeric', 'numeric']);
    expect(result.columnDeclaredTypes, ['TEXT', 'INT', 'REAL']);
    expect(result.rows, isEmpty);
    expect(
        (await db.query('SELECT value=1 FROM '
                '(SELECT (SELECT a FROM t) AS value)'))
            .rows
            .single,
        [BigInt.zero]);
    expect(
        (await db.query("SELECT value='01' FROM "
                '(SELECT (SELECT b FROM t) AS value)'))
            .rows
            .single,
        [BigInt.one]);
  });

  test('scalar compounds inherit rightmost metadata and materialize CTAS types',
      () async {
    await db.execute('CREATE TABLE copied AS SELECT '
        '(SELECT a FROM t UNION ALL SELECT b FROM t) AS integer_value,'
        '(SELECT b FROM t UNION ALL SELECT a FROM t) AS text_value,'
        '(SELECT c FROM t) AS real_value');
    expect((await db.query('PRAGMA table_info(copied)')).rows.map((r) => r[2]),
        ['INT', 'TEXT', 'REAL']);
    expect((await db.query('SELECT * FROM copied')).rows.single,
        [BigInt.one, '1', 1.0]);
    expect(
        (await db.query('SELECT '
                '(SELECT a FROM t UNION ALL SELECT b FROM t)=1,'
                '(SELECT b FROM t UNION ALL SELECT a FROM t)=\'01\''))
            .rows
            .single,
        [BigInt.one, BigInt.zero]);
  });

  test('correlated and nested scalar metadata preserves integer type',
      () async {
    await db.execute('CREATE TABLE copied AS SELECT '
        '(SELECT (SELECT t.b)) AS value FROM t');
    expect((await db.query('PRAGMA table_info(copied)')).rows.single[2], 'INT');
    expect((await db.query('SELECT * FROM copied')).rows.single.single,
        BigInt.one);
  });

  test('metadata never executes scalar callbacks, including LIMIT zero CTAS',
      () async {
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('CREATE TABLE copied AS SELECT '
        '(SELECT CAST(tick() AS INTEGER)) AS value LIMIT 0');
    expect(calls, 0);
    expect((await db.query('PRAGMA table_info(copied)')).rows.single[2], 'INT');
    expect((await db.query('SELECT (SELECT tick())')).rows.single.single,
        BigInt.one);
    expect(calls, 1);
  });
}
