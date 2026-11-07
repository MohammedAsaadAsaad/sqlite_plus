import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusSearch search;
  const config = FuzzySearchConfig(learnAfter: 5);
  setUp(() async {
    db = await openInMemory();
    search = await SqlitePlusSearch.open(database: db);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db
        .execute("INSERT INTO docs VALUES (1,'بسكويت جودة'),(2,'سكر جودة')");
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
  });
  tearDown(() => db.close());
  Future<SearchResults> find(
          {FuzzySearchConfig? fuzzy = config, bool record = true}) =>
      search.search('جودة بسكوت',
          table: 'docs', fuzzy: fuzzy, recordFuzzyLearning: record);
  test('five successes activate sixth lookup and persist across reopen',
      () async {
    for (var i = 0; i < 5; i++) {
      final r = await find();
      expect(r.hits.single.documentId, '1');
      expect(r.fuzzyCacheUsed, false);
      expect(r.fuzzyLearningChanged, true);
      if (i < 4) {
        expect(
            (await db.query('SELECT alternatives FROM _sps_fuzzy_learning'))
                .rows
                .every((row) => row.single == '[]'),
            true);
      }
    }
    final r = await find();
    expect(r.fuzzyCacheUsed, true);
    expect(r.fuzzyLearningChanged, false);
    await search.verifyIndex(table: 'docs');
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    final other = await SqlitePlusSearch.open(database: copy);
    expect(
        (await other.search('جودة بسكوت', table: 'docs', fuzzy: config))
            .fuzzyCacheUsed,
        true);
    expect(
        (await find(fuzzy: const FuzzySearchConfig())).fuzzyCacheUsed, false);
  });
  test('disabled failed and pagination queries do not train', () async {
    await find(fuzzy: const FuzzySearchConfig());
    expect(
        (await db.query(
                "SELECT name FROM sqlite_schema WHERE name='_sps_fuzzy_learning'"))
            .rows,
        isEmpty);
    for (var i = 0; i < 6; i++) {
      await find(record: false);
      await search.search('zzzzzzzz', table: 'docs', fuzzy: config);
      await search.search('جودة بسكوت',
          table: 'docs', fuzzy: config, offset: 1);
    }
    expect((await find()).fuzzyCacheUsed, false);
    expect(
        (await db.query('SELECT n FROM _sps_fuzzy_learning'))
            .rows
            .every((r) => r.single == BigInt.one),
        true);
    await expectLater(find(fuzzy: const FuzzySearchConfig(learnAfter: 0)),
        throwsArgumentError);
  });
  test('rebuild replay and rollback invalidate correctly', () async {
    const instant = FuzzySearchConfig(learnAfter: 1);
    await find(fuzzy: instant);
    expect((await find(fuzzy: instant)).fuzzyCacheUsed, true);
    await db.execute('BEGIN');
    await db.execute("UPDATE docs SET body='cracker' WHERE id=1");
    await db.execute('ROLLBACK');
    expect((await find(fuzzy: instant)).fuzzyCacheUsed, true);
    await db.execute("UPDATE docs SET body='cracker' WHERE id=1");
    expect((await find(fuzzy: instant)).hits, isEmpty);
    expect(
        (await db.query('SELECT count(*) FROM _sps_fuzzy_learning'))
            .rows
            .single
            .single,
        BigInt.zero);
    await db.execute("UPDATE docs SET body='بسكويت جودة' WHERE id=1");
    await find(fuzzy: instant);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    expect((await find(fuzzy: instant)).fuzzyCacheUsed, false);
  });
  test('corrupt alternatives fail explicitly and rebuild recovers', () async {
    const instant = FuzzySearchConfig(learnAfter: 1);
    await find(fuzzy: instant);
    await db.execute("UPDATE _sps_fuzzy_learning SET alternatives='broken'");
    await expectLater(find(fuzzy: instant), throwsStateError);
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    expect((await find(fuzzy: instant)).hits.single.documentId, '1');
  });
}
