import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase source;
  late SqliteDatabase reader;
  Future<SqliteDatabase> snapshot() =>
      SqliteDatabase.openReadOnly(ByteImageStorage(source.exportImage()),
          functions: source.functions);
  setUp(() async {
    source = await openInMemory();
    await source
        .execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER,s TEXT)');
    await source.execute("INSERT INTO t VALUES ${[
      for (var i = 1; i <= 100; i++) "($i,${i % 17},'a')"
    ].join(',')}");
    reader = await snapshot();
  });
  tearDown(() async {
    await reader.close();
    await source.close();
  });
  test(
      'actual loaded/visited/matched/output counts and heap agree with real query',
      () async {
    const sql = 'SELECT id,n FROM t WHERE n>=? ORDER BY n,id LIMIT ? OFFSET ?';
    final normal = await reader.query(sql, [5, 32, 3]);
    final before = reader.pagesRead;
    final report = await reader.diagnoseQuery(sql, parameters: [5, 32, 3]);
    expect(report.result.rows, normal.rows);
    expect(report.rowsLoaded, 100);
    expect(report.rowsVisited, 100);
    expect(report.rowsMatched, 71);
    expect(report.result.rows.length, 32);
    expect(report.sortStrategy, 'bounded-heap');
    expect(report.peakSortRows, 35);
    expect(report.pageReads, reader.pagesRead - before);
    expect(report.plan.access, reader.explain(sql, [5, 32, 3]).access);
    expect(
        report.planningTime, lessThanOrEqualTo(report.sourcePreparationTime));
    expect(report.totalTime, greaterThanOrEqualTo(report.evaluationTime));
    expect(() => report.decisions.clear(), throwsUnsupportedError);
    expect(report.toJson()['sortComparisons'], isNull);
  });
  test('early consumption is distinct from upstream materialization', () async {
    final report =
        await reader.diagnoseQuery('SELECT id FROM t LIMIT 1 OFFSET 5');
    expect(report.result.rows, [
      [BigInt.from(6)]
    ]);
    expect(report.rowsLoaded, 100);
    expect(report.rowsVisited, 6);
    expect(report.rowsMatched, 6);
    expect(report.sortStrategy, 'none');
    expect(report.peakSortRows, 0);
    final zero =
        await reader.diagnoseQuery('SELECT id FROM t ORDER BY n LIMIT 0');
    expect(zero.rowsVisited, 0);
    expect(zero.rowsMatched, 0);
    expect(zero.sortStrategy, 'none');
    final physical =
        await reader.diagnoseQuery('SELECT id FROM t ORDER BY id DESC LIMIT 1');
    expect(physical.sortStrategy, 'input-order');
    expect(physical.rowsVisited, 1);
  });
  test('actual planner decisions, hint rules, truncation and STAT1 estimates',
      () async {
    await source.execute('CREATE INDEX idx_n ON t(n)');
    await source.execute('CREATE INDEX idx_s ON t(s)');
    await source.execute('CREATE INDEX partial_id ON t(id) WHERE n>50');
    await source.execute('ANALYZE');
    await reader.close();
    reader = await snapshot();
    final report = await reader
        .diagnoseQuery('SELECT id FROM t WHERE n=?', parameters: [2]);
    expect(report.plan.indexName, 'idx_n');
    expect(report.estimatedRows, isNotNull);
    expect(report.enumeratedCandidates, 3);
    expect(
        report.decisions.any((d) => d.reason == 'partial-predicate-not-proved'),
        true);
    expect(
        report.decisions.any((d) => d.reason == 'no-compatible-leading-prefix'),
        true);
    expect(report.selectedDecisionCaptured, true);
    final zero = await reader.diagnoseQuery('SELECT id FROM t WHERE n=?',
        parameters: [2], options: const SqlDiagnosticOptions(maxCandidates: 0));
    expect(zero.decisions, isEmpty);
    expect(zero.enumeratedCandidates, 3);
    expect(zero.decisionsTruncated, true);
    expect(zero.selectedDecisionCaptured, false);
    expect(zero.result.rows, report.result.rows);
    final hint = await reader.diagnoseQuery(
        'SELECT id FROM t INDEXED BY idx_n WHERE s=?',
        parameters: ['a']);
    expect(hint.plan.access, 'secondary-index-scan');
    expect(hint.decisions.last.reason, 'INDEXED-BY-scan');
    final notIndexed =
        await reader.diagnoseQuery('SELECT id FROM t NOT INDEXED WHERE n=2');
    expect(notIndexed.plan.access, 'table-scan');
    expect(notIndexed.decisions.single.reason, 'NOT-INDEXED');
  });
  test('diagnostic index identifiers are bounded Unicode strings', () async {
    final name = List.filled(180, '😀').join();
    await source.execute('CREATE INDEX "$name" ON t(n)');
    await reader.close();
    reader = await snapshot();
    final report = await reader.diagnoseQuery('SELECT id FROM t WHERE n=2');
    expect(report.plan.indexName!.runes.length, 128);
    expect(report.decisions.single.indexName!.runes.length, 128);
    expect(report.selectedDecisionCaptured, true);
  });
  test('scalar callbacks execute once with identical projection decisions',
      () async {
    final calls = <String>[];
    source.functions.registerScalar('visit', 1, (args) {
      calls.add('v:${args.single}');
      return BigInt.one;
    });
    source.functions.registerScalar('mark', 1, (args) {
      calls.add('m:${args.single}');
      return args.single;
    });
    const sql = 'SELECT mark(id) FROM t WHERE visit(n) ORDER BY n,id LIMIT 32';
    final normal = await reader.query(sql);
    final expected = List<String>.of(calls);
    calls.clear();
    final report = await reader.diagnoseQuery(sql);
    expect(report.result.rows, normal.rows);
    expect(calls, expected);
    expect(report.rowsVisited, 100);
    expect(report.rowsMatched, 100);
  });
  test('privacy, immutable BLOB snapshot, constant SELECT and strict bindings',
      () async {
    const secret = 'binding-secret-not-for-diagnostic-json';
    final constant =
        await reader.diagnoseQuery('SELECT ?', parameters: [secret]);
    expect(constant.result.rows, [
      [secret]
    ]);
    expect(constant.rowsLoaded, 1);
    expect(constant.rowsVisited, 1);
    expect(constant.plan.access, 'constant');
    expect(constant.planningTime, Duration.zero);
    final metadata = jsonEncode(constant.toJson());
    expect(metadata.contains(secret), false);
    expect(metadata.contains('SELECT'), false);
    final key = await reader
        .diagnoseQuery('SELECT n FROM t WHERE id=?', parameters: [99]);
    expect(key.plan.access, 'rowid-lookup');
    expect(key.estimatedRows, 1);
    expect(key.toJson()['plan'], isNot(contains('rowid')));
    final bytes = Uint8List.fromList([1]);
    final pending = reader.diagnoseQuery('SELECT ?', parameters: [bytes]);
    bytes[0] = 9;
    expect((await pending).result.rows.single.single, [1]);
    await expectLater(
        reader.diagnoseQuery('SELECT ?'), throwsA(isA<SqlException>()));
    await expectLater(
        reader.diagnoseQuery('SELECT 1',
            options: const SqlDiagnosticOptions(maxCandidates: 257)),
        throwsArgumentError);
  });
  test(
      'unsupported scopes reject before callbacks; errors do not poison later reads',
      () async {
    var calls = 0;
    source.functions.registerScalar('mark', 1, (args) {
      calls++;
      return args.single;
    });
    for (final sql in [
      'WITH x AS(SELECT 1) SELECT mark(1) FROM x',
      'SELECT mark(a.id) FROM t AS a JOIN t AS b ON a.id=b.id',
      'SELECT mark(id) FROM t GROUP BY id',
      'SELECT mark(id),row_number() OVER(ORDER BY id) FROM t',
      'SELECT count(*) FROM t',
      'SELECT id FROM t LIMIT (SELECT mark(1))',
      'SELECT (SELECT mark(1)) IN () FROM t',
      'PRAGMA integrity_check',
    ]) {
      await expectLater(reader.diagnoseQuery(sql), throwsUnsupportedError);
    }
    expect(calls, 0);
    await expectLater(reader.diagnoseQuery('SELECT missing FROM t'),
        throwsA(isA<SqlException>()));
    expect((await reader.diagnoseQuery('SELECT 1')).result.rows, [
      [BigInt.one]
    ]);
    await reader.close();
    await expectLater(reader.diagnoseQuery('SELECT 1'), throwsStateError);
  });
  test(
      'mutable diagnosis routes temp/main/attached images and excludes overlap',
      () async {
    await source
        .execute('CREATE TEMP TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await source.execute('INSERT INTO temp.t VALUES(1,77)');
    expect((await source.diagnoseQuery('SELECT n FROM t')).result.rows, [
      [BigInt.from(77)]
    ]);
    expect(
        (await source.diagnoseQuery('SELECT n FROM main.t WHERE id=1'))
            .result
            .rows,
        [
          [BigInt.one]
        ]);
    await source.execute("ATTACH ':memory:' AS aux");
    await source
        .execute('CREATE TABLE aux.u(id INTEGER PRIMARY KEY,n INTEGER)');
    await source.execute('INSERT INTO aux.u VALUES(1,55)');
    expect((await source.diagnoseQuery('SELECT n FROM aux.u')).result.rows, [
      [BigInt.from(55)]
    ]);
    await expectLater(
        source.diagnoseQuery(
            'SELECT main.t.id FROM main.t JOIN aux.u ON main.t.id=aux.u.id'),
        throwsUnsupportedError);
    final pending =
        source.diagnoseQuery('SELECT n FROM main.t ORDER BY n LIMIT 32');
    await expectLater(source.diagnoseQuery('SELECT 1'), throwsStateError);
    await pending;
  });
  test('mutable diagnostic callbacks preserve nested-write rejection',
      () async {
    var rejected = 0;
    Future<void>? nested;
    source.functions.registerScalar('touch', 1, (args) {
      nested = source
          .execute('UPDATE t SET n=999 WHERE id=1')
          .then<void>((_) => fail('Nested write unexpectedly succeeded'),
              onError: (Object error) {
        expect(error, isA<StateError>());
        rejected++;
      });
      return args.single;
    });
    final normal = await source.query('SELECT touch(n) FROM t WHERE id=1');
    await nested;
    final report =
        await source.diagnoseQuery('SELECT touch(n) FROM t WHERE id=1');
    await nested;
    expect(report.result.rows, normal.rows);
    expect(rejected, 2);
    expect((await source.query('SELECT n FROM t WHERE id=1')).rows, [
      [BigInt.one]
    ]);
  });
  test(
      'support validation walks long scalar expressions without changing evaluation',
      () async {
    final where = List.filled(128, 'n>=0').join(' AND ');
    final sql = 'SELECT id FROM t WHERE $where LIMIT 2';
    final report = await reader.diagnoseQuery(sql);
    expect(report.result.rows, (await reader.query(sql)).rows);
    expect(report.rowsVisited, 2);
    expect(
        (await reader.diagnoseQuery('SELECT min(n,3) FROM t WHERE id=1'))
            .result
            .rows,
        [
          [BigInt.one]
        ]);
  });
  test(
      'DISTINCT, unlimited and small-capacity strategies retain normal results',
      () async {
    for (final sql in [
      'SELECT n FROM t ORDER BY n LIMIT 1',
      'SELECT n FROM t ORDER BY n LIMIT -1',
      'SELECT DISTINCT n FROM t ORDER BY n LIMIT 32'
    ]) {
      final report = await reader.diagnoseQuery(sql);
      expect(report.result.rows, (await reader.query(sql)).rows);
      if (sql.contains('DISTINCT')) {
        expect(report.sortStrategy, 'full-sort-distinct');
        expect(report.peakSortRows, isNull);
      } else if (sql.contains('-1')) {
        expect(report.sortStrategy, 'full-sort');
        expect(report.peakSortRows, 100);
      } else {
        expect(report.sortStrategy, 'bounded-linear');
        expect(report.peakSortRows, 1);
      }
    }
  });
}
