import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

final class CountingProvider implements LocalEmbeddingProvider {
  int calls = 0;
  @override
  String get modelId => 'counting-fixture-v1';
  @override
  int get dimensions => 2;
  @override
  Future<List<double>> embed(String text) async {
    calls++;
    return [1, 0];
  }
}

void main() {
  test(
      'coalesced explicit sync embeds one changed document and preserves text key spelling',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id TEXT PRIMARY KEY COLLATE NOCASE,body TEXT)');
    await db.execute("INSERT INTO docs VALUES ('A','milk'),('other','tea')");
    final provider = CountingProvider();
    final search =
        await SqlitePlusSearch.open(database: db, embeddingProvider: provider);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    expect(provider.calls, 2);
    provider.calls = 0;
    await db.execute("UPDATE docs SET body='coffee' WHERE id='A'");
    await db.execute("UPDATE docs SET body='milk coffee' WHERE id='A'");
    await search.synchronize(table: 'docs');
    expect(provider.calls, 1);
    await db.execute("UPDATE docs SET id='a' WHERE id='A'");
    await search.synchronize(table: 'docs');
    expect(
        (await search.search('coffee', table: 'docs')).hits.single.documentId,
        'a');
    expect(
        (await db.query('SELECT count(*) FROM _sps_1_keys')).rows.single.single,
        BigInt.two);
    await search.verifyIndex(table: 'docs');
  });
  test(
      'older development format is rejected until explicit rebuild, without changing source records',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db.execute("INSERT INTO docs VALUES (1,'milk')");
    final search = await SqlitePlusSearch.open(database: db);
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    await db.execute('UPDATE _sps_collections SET version=1');
    await expectLater(
        search.search('milk', table: 'docs'),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('explicitly rebuild'))));
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    expect((await search.search('milk', table: 'docs')).hits.single.documentId,
        '1');
    expect(
        (await db.query('SELECT body FROM docs')).rows.single.single, 'milk');
  });
}
