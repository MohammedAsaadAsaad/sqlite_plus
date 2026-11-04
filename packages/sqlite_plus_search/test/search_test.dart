import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusSearch search;
  setUp(() async {
    db = await openInMemory();
    search = await SqlitePlusSearch.open(database: db);
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT, category TEXT)');
    await db.execute('INSERT INTO products VALUES (1,?,?), (2,?,?), (3,?,?)',
        ['milk حَلِيب', 'a', 'milk حليب', 'b', 'tea', 'a']);
  });
  tearDown(() => db.close());
  Future<void> index() => search
      .indexTable(table: 'products', primaryKey: 'id', textColumns: ['name']);

  test('index existing table, stable IDs, bound filter before pagination',
      () async {
    await index();
    expect(
        (await search.search('حليب', table: 'products'))
            .hits
            .map((h) => h.documentId),
        ['1', '2']);
    final filtered = await search.search('milk',
        table: 'products',
        limit: 1,
        filter: SearchFilter('category = ?', ['b']));
    expect(filtered.hits.single.documentId, '2');
    expect(filtered.total, 1);
    expect(
        (await search.search('milk', table: 'products', offset: 1))
            .hits
            .single
            .documentId,
        '2');
    expect((await db.query('SELECT count(*) FROM products')).rows.single.single,
        BigInt.from(3));
  });

  test('index image persists and schema/analyzer changes require rebuild',
      () async {
    await index();
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    final other = await SqlitePlusSearch.open(database: reopened);
    expect((await other.search('حليب', table: 'products')).hits.length, 2);
    await reopened.execute('ALTER TABLE products ADD COLUMN price INTEGER');
    await expectLater(
        other.search('milk', table: 'products'), throwsStateError);
    await other
        .indexTable(table: 'products', primaryKey: 'id', textColumns: ['name']);
    expect((await other.search('milk', table: 'products')).hits.length, 2);
    final changed = await SqlitePlusSearch.open(
        database: reopened,
        analyzer: const SearchTextAnalyzer(stemArabic: true));
    await expectLater(
        changed.search('milk', table: 'products'), throwsStateError);
  });

  test('failed rebuild rolls back to prior searchable index', () async {
    await index();
    await db.execute('UPDATE products SET name = 42 WHERE id = 1');
    // TEXT affinity coerces numbers, so use a blob for invalid indexed content.
    await db.execute("UPDATE products SET name = x'0102' WHERE id = 1");
    await expectLater(index(), throwsArgumentError);
    expect((await search.search('milk', table: 'products')).hits.length, 2);
    expect(db.inTransaction, isFalse);
  });

  test(
      'empty, duplicate content, malformed arguments and explicit unsupported modes',
      () async {
    await index();
    expect((await search.search('', table: 'products')).hits, isEmpty);
    expect((await search.search('missing', table: 'products')).hits, isEmpty);
    await expectLater(
        search.search('milk', table: 'products', mode: SearchMode.semantic),
        throwsUnsupportedError);
    await expectLater(search.search('milk', table: 'products', limit: 0),
        throwsArgumentError);
    await expectLater(
        search.indexTable(table: 'products', primaryKey: 'id', textColumns: []),
        throwsArgumentError);
    expect(
        () => SearchFilter('id=1; DROP TABLE products'), throwsArgumentError);
    await db.execute('DELETE FROM products');
    await index();
    expect((await search.search('milk', table: 'products')).total, 0);
  });

  test(
      'facade operations serialize and caller transactions remain caller owned',
      () async {
    await Future.wait([index(), index(), index()]);
    final results = await Future.wait(
        List.generate(5, (_) => search.search('milk', table: 'products')));
    expect(results.every((result) => result.hits.length == 2), isTrue);
    await db.execute('BEGIN');
    await expectLater(index(), throwsStateError);
    expect(db.inTransaction, isTrue);
    await db.execute('ROLLBACK');
    expect((await search.search('milk', table: 'products')).hits.length, 2);
  });

  test('explicit rebuild recovers damaged mapping and refreshes source edits',
      () async {
    await index();
    await db.execute('DELETE FROM _sps_1_keys WHERE id = 1');
    await expectLater(
        search.search('milk', table: 'products'), throwsStateError);
    await index();
    expect((await search.search('milk', table: 'products')).total, 2);
    await db.execute('UPDATE products SET name = ? WHERE id = 1', ['coffee']);
    await db.execute('DELETE FROM products WHERE id = 2');
    await db.execute('INSERT INTO products VALUES (4,?,?)', ['coffee', 'a']);
    await index();
    expect((await search.search('milk', table: 'products')).total, 0);
    expect(
        (await search.search('coffee', table: 'products'))
            .hits
            .map((h) => h.documentId),
        ['1', '4']);
  });

  test('metadata remains visible after empty indexed lookup in transaction',
      () async {
    // NOT INDEXED on metadata reads avoids the engine's stale empty unique
    // lookup path. Keep this regression while that engine issue is unresolved.
    await index();
    await index();
    expect((await db.query('SELECT source FROM _sps_collections')).rows, [
      ['products']
    ]);
  });

  test('batch boundary preserves every mapping, FTS row and duplicate document',
      () async {
    await db.execute('DELETE FROM products');
    await db.execute(
        'INSERT INTO products VALUES ${List.filled(1003, '(?,?,?)').join(',')}',
        [
          for (var i = 1; i <= 1003; i++) ...[i, 'same milk', 'a']
        ]);
    await index();
    final results = await search.search('milk', table: 'products', limit: 2000);
    expect(results.total, 1003);
    expect(results.hits.map((h) => h.documentId).toSet().length, 1003);
    expect(results.hits.any((h) => h.documentId == '1003'), isTrue);
  });

  test(
      'literal punctuation and unsupported offline flags fail without corruption',
      () async {
    await index();
    for (final query in ['"', '(', ')', '*', 'OR', 'NEAR', '---', '\u0000']) {
      expect((await search.search(query, table: 'products')).hits, isEmpty);
    }
    await expectLater(SqlitePlusSearch.open(database: db, offlineOnly: false),
        throwsArgumentError);
    expect((await search.search('milk', table: 'products')).total, 2);
    await db.execute('UPDATE _sps_collections SET version=99');
    await expectLater(
        search.search('milk', table: 'products'), throwsStateError);
  });

  test('text keys and quoted identifiers are preserved', () async {
    await db.execute(
        'CREATE TABLE "odd table"("the key" TEXT PRIMARY KEY, "text column" TEXT)');
    await db.execute('INSERT INTO "odd table" VALUES (?,?)', ['a"b', 'hello']);
    await search.indexTable(
        table: 'odd table',
        primaryKey: 'the key',
        textColumns: ['text column']);
    expect(
        (await search.search('hello', table: 'odd table'))
            .hits
            .single
            .documentId,
        'a"b');
  });
}
