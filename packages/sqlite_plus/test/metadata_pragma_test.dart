import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class _Count extends SqlAggregate {
  @override
  void step(List<Object?> arguments) {}
  @override
  Object? finish() => BigInt.zero;
}

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create();
  });
  tearDown(() => db.close());

  test('table_list describes main tables, views, generated fields and STRICT',
      () async {
    await db.execute('CREATE TABLE ordinary(a,b AS(a+1),c AS(a+2) STORED)');
    await db
        .execute('CREATE TABLE keyed(a TEXT PRIMARY KEY,b INT) WITHOUT ROWID');
    await db.execute('CREATE TABLE typed(a INT PRIMARY KEY,b TEXT) STRICT');
    await db.execute('CREATE VIEW visible AS SELECT a,b FROM ordinary');
    final result = await db.query('PRAGMA main.table_list');
    expect(result.columns, ['schema', 'name', 'type', 'ncol', 'wr', 'strict']);
    final byName = {for (final row in result.rows) row[1]: row.sublist(2)};
    expect(byName, {
      'ordinary': ['table', BigInt.from(3), BigInt.zero, BigInt.zero],
      'keyed': ['table', BigInt.two, BigInt.one, BigInt.zero],
      'typed': ['table', BigInt.two, BigInt.zero, BigInt.one],
      'visible': ['view', BigInt.two, BigInt.zero, BigInt.zero],
      'sqlite_schema': ['table', BigInt.from(5), BigInt.zero, BigInt.zero],
    });
    expect((await db.query("PRAGMA table_list='OrDiNaRy'")).rows.single[1],
        'ordinary');
    expect((await db.query('PRAGMA table_list(missing)')).rows, isEmpty);
    expect((await db.query('PRAGMA table_list(sqlite_master)')).rows.single[1],
        'sqlite_schema');
    expect((await db.query('PRAGMA table_list(sqlite_schema)')).rows, isEmpty);
  });

  test('view info has derived names and types without copied constraints',
      () async {
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT NOT NULL '
        "DEFAULT 'x',b REAL,c,d INT AS(id+1))");
    await db.execute('CREATE VIEW v AS SELECT *,CAST(a AS INTEGER) AS k,'
        'CAST(a AS NUMERIC) AS n,a+1 AS expr,id AS id FROM t');
    final result = await db.query('PRAGMA table_xinfo(v)');
    expect(result.columns,
        ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk', 'hidden']);
    expect(result.rows.map((r) => r[1]),
        ['id', 'a', 'b', 'c', 'd', 'k', 'n', 'expr', 'id:1']);
    expect(result.rows.map((r) => r[2]), [
      'INTEGER',
      'TEXT',
      'REAL',
      'BLOB',
      'INT',
      'INT',
      'NUM',
      '',
      'INTEGER'
    ]);
    for (final row in result.rows) {
      expect(row.sublist(3), [BigInt.zero, null, BigInt.zero, BigInt.zero]);
    }
    expect((await db.query('PRAGMA table_info(missing)')).rows, isEmpty);
    expect((await db.query('PRAGMA main.table_info=v')).rows.length, 9);
  });

  test('metadata never evaluates callbacks, defaults, CTEs or view LIMIT',
      () async {
    var calls = 0;
    db.functions.registerScalar('observed', 0, (_) {
      calls++;
      throw StateError('metadata must not invoke this function');
    });
    await db.execute('CREATE TABLE t(a INT DEFAULT (observed()))');
    await db.execute('CREATE VIEW v(x) AS WITH q AS (SELECT observed() AS x) '
        'SELECT observed() FROM q WHERE observed() LIMIT observed()');
    await db.execute('CREATE VIEW nested AS SELECT * FROM v');
    expect((await db.query('PRAGMA table_info(nested)')).rows.single,
        [BigInt.zero, 'x', '', BigInt.zero, null, BigInt.zero]);
    expect((await db.query('PRAGMA table_list(v)')).rows.single[3], BigInt.one);
    expect(calls, 0);
  });

  test('recursive CTE and join view metadata does not run rows', () async {
    await db.execute('CREATE TABLE a(x INT,y TEXT)');
    await db.execute('CREATE TABLE b(x INT,z BLOB)');
    await db
        .execute('CREATE VIEW joined AS SELECT * FROM a LEFT JOIN b USING(x)');
    await db.execute('CREATE VIEW recursive AS WITH RECURSIVE q(x) AS '
        '(VALUES(1) UNION ALL SELECT x+1 FROM q) SELECT x FROM q');
    expect((await db.query('PRAGMA table_info(joined)')).rows.map((r) => r[1]),
        ['x', 'y', 'z']);
    expect(
        (await db.query('PRAGMA table_info(recursive)')).rows.single[1], 'x');
  });

  test('connection metadata lists only the supported image identity', () async {
    expect((await db.query('PRAGMA database_list')).rows, [
      [BigInt.zero, 'main', '']
    ]);
    expect((await db.query('PRAGMA collation_list')).rows, [
      [BigInt.zero, 'RTRIM'],
      [BigInt.one, 'NOCASE'],
      [BigInt.two, 'BINARY']
    ]);
    final names = (await db.query('PRAGMA pragma_list')).rows.map((r) => r[0]);
    expect(names, containsAll(['table_list', 'function_list', 'table_xinfo']));
    expect(names, isNot(contains('journal_mode')));
    expect(names.toSet().length, names.length);
    await expectLater(
        db.query('PRAGMA other.table_list'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('PRAGMA table_list(?)'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('PRAGMA table_list', [1]), throwsA(isA<SqlException>()));
  });

  test('scalar and correlated subqueries retain metadata without evaluation',
      () async {
    var calls = 0;
    db.functions.registerScalar('metadata_probe', 0, (_) {
      calls++;
      throw StateError('metadata must not evaluate scalar subqueries');
    });
    await db.execute('CREATE TABLE source(a TEXT COLLATE NOCASE,b INT,c)');
    await db.execute('CREATE VIEW scalar_metadata AS SELECT '
        '(SELECT a FROM source) AS a,'
        '(SELECT CAST(b AS INTEGER) FROM source) AS b,'
        '(SELECT CAST(a AS VARCHAR(8)) FROM source) AS text_value,'
        '(SELECT (SELECT c FROM source)) AS untyped,'
        '(SELECT source.b WHERE metadata_probe()) AS correlated,'
        'EXISTS(SELECT b FROM source) AS present,'
        '+(SELECT b FROM source) AS unary,'
        '(WITH q AS (SELECT b FROM source) SELECT b FROM q) AS cte_value '
        'FROM source WHERE metadata_probe() LIMIT metadata_probe()');
    final info = await db.query('PRAGMA table_xinfo(scalar_metadata)');
    expect(info.rows.map((r) => r[1]), [
      'a',
      'b',
      'text_value',
      'untyped',
      'correlated',
      'present',
      'unary',
      'cte_value'
    ]);
    expect(info.rows.map((r) => r[2]),
        ['TEXT', 'INT', 'TEXT', 'BLOB', 'INT', '', '', 'INT']);
    expect(calls, 0);
  });

  test('materialized metadata deduplicates CTE and derived source labels',
      () async {
    await db.execute('CREATE TABLE t(a TEXT,b INT)');
    await db.execute('CREATE VIEW cte_metadata AS WITH q(x,x) AS '
        '(SELECT a,b FROM t) SELECT x,"x:1" FROM q');
    await db.execute('CREATE VIEW derived_metadata AS SELECT a,"a:1" '
        'FROM (SELECT a,b AS a FROM t)');
    for (final name in ['cte_metadata', 'derived_metadata']) {
      final info = await db.query('PRAGMA table_info($name)');
      expect(info.rows.map((r) => r[2]), ['TEXT', 'INT']);
      expect(info.rows.map((r) => r[1]),
          name == 'cte_metadata' ? ['x', 'x:1'] : ['a', 'a:1']);
    }
  });

  test('metadata gives real rowid fields precedence over implicit aliases',
      () async {
    await db.execute('CREATE TABLE a(value INT)');
    await db.execute('CREATE TABLE b(rowid TEXT)');
    await db.execute('CREATE VIEW rowid_metadata AS SELECT rowid FROM a,b');
    expect((await db.query('PRAGMA table_info(rowid_metadata)')).rows.single[2],
        'TEXT');
  });

  test('scalar compound metadata uses the final arm and checks widths',
      () async {
    await db.execute('CREATE TABLE t(a TEXT,b REAL)');
    await db.execute('CREATE VIEW scalar_compound AS SELECT '
        '(SELECT a FROM t UNION ALL SELECT b FROM t) AS value');
    expect(
        (await db.query('PRAGMA table_info(scalar_compound)')).rows.single[2],
        'REAL');
    await db.execute('CREATE VIEW invalid_scalar AS SELECT '
        '(SELECT * FROM t) AS value');
    await expectLater(db.query('PRAGMA table_info(invalid_scalar)'),
        throwsA(isA<SqlException>()));
  });

  test('main-schema metadata bypasses CTE shadows and binds qualified fields',
      () async {
    await db.execute('CREATE TABLE t(a TEXT,b INT)');
    await db.execute('CREATE VIEW base AS SELECT a,b FROM main.t');
    await db.execute('CREATE VIEW main_metadata AS WITH t(a) AS (VALUES(1)) '
        'SELECT main.physical.a, main.physical.b FROM main.base AS physical');
    final info = await db.query('PRAGMA main.table_info(main_metadata)');
    expect(info.rows.map((r) => r[1]), ['a', 'b']);
    expect(info.rows.map((r) => r[2]), ['TEXT', 'INT']);
  });

  test('function_list describes builtin overloads and live callback signatures',
      () async {
    db.functions
        .registerScalar('My_Function', 1, (_) => 0, deterministic: true);
    db.functions.registerScalar('My_Function', -1, (_) => 0);
    db.functions.registerAggregate('my_aggregate', 2, _Count.new);
    final result = await db.query('PRAGMA function_list');
    expect(result.columns, ['name', 'builtin', 'type', 'enc', 'narg', 'flags']);
    final registered =
        result.rows.where((r) => (r[0] as String).startsWith('my_')).toList();
    expect(registered, [
      ['my_function', BigInt.zero, 's', 'utf8', BigInt.one, BigInt.from(2048)],
      ['my_function', BigInt.zero, 's', 'utf8', -BigInt.one, BigInt.zero],
      ['my_aggregate', BigInt.zero, 'a', 'utf8', BigInt.two, BigInt.zero]
    ]);
    expect(result.rows.where((r) => r[0] == 'min').map((r) => r.sublist(2)), [
      ['w', 'utf8', BigInt.one, BigInt.from(2097152)],
      ['s', 'utf8', BigInt.from(-3), BigInt.from(2099200)]
    ]);
    expect(result.rows.where((r) => r[0] == 'coalesce').single[4],
        BigInt.from(-4));
    expect(result.rows.where((r) => r[0] == 'match'), [
      ['match', BigInt.zero, 's', 'utf8', BigInt.two, BigInt.zero]
    ]);
    db.functions.unregister('MY_FUNCTION', 1);
    expect(
        (await db.query('PRAGMA function_list'))
            .rows
            .where((r) => r[0] == 'my_function')
            .length,
        1);
  });

  test('joined group metadata preserves hidden qualifiers and allocated names',
      () async {
    await db.execute('CREATE TABLE a(x INT,y TEXT COLLATE NOCASE)');
    await db.execute('CREATE TABLE b(x TEXT,y REAL,z BLOB)');
    await db.execute('CREATE TABLE c(x INT,w TEXT)');
    await db.execute('CREATE VIEW grouped AS SELECT q.x,q."x:1",q.y,q."y:1" '
        'FROM (a JOIN b USING(x)) AS q');
    final grouped = await db.query('PRAGMA table_info(grouped)');
    expect(grouped.rows.map((row) => row[1]), ['x', 'x:1', 'y', 'y:1']);
    expect(grouped.rows.map((row) => row[2]), ['INT', 'INT', 'TEXT', 'REAL']);
    await db.execute('CREATE VIEW right_group AS SELECT * '
        'FROM a LEFT JOIN (b JOIN c USING(x)) USING(x)');
    final right = await db.query('PRAGMA table_info(right_group)');
    expect(right.rows.map((row) => row[1]), ['x', 'y', 'y:1', 'z', 'w']);
    expect(right.rows.map((row) => row[2]),
        ['INT', 'TEXT', 'REAL', 'BLOB', 'TEXT']);
  });

  test('joined group metadata never reads callbacks in any query clause',
      () async {
    var calls = 0;
    db.functions.registerScalar('metadata_probe', 0, (_) {
      calls++;
      throw StateError('metadata evaluated a joined group');
    });
    await db.execute('CREATE TABLE a(x INT)');
    await db.execute('CREATE TABLE b(x INT,y TEXT)');
    await db.execute('CREATE TABLE c(x INT)');
    await db.execute('CREATE VIEW observed_group AS SELECT * FROM a LEFT JOIN '
        '(b JOIN c ON metadata_probe()) AS q ON metadata_probe() '
        'WHERE metadata_probe() LIMIT metadata_probe()');
    expect(
        (await db.query('PRAGMA table_info(observed_group)')).rows.length, 4);
    expect(calls, 0);
  });
}
