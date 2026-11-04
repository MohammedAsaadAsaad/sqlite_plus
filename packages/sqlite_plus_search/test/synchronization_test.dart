import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test(
      'secondary-unique REPLACE removes displaced index entries with recursive triggers off',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY,sku TEXT UNIQUE,body TEXT)');
    await db.execute("INSERT INTO docs VALUES (1,'a','milk'),(2,'b','tea')");
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    await db.execute("INSERT OR REPLACE INTO docs VALUES (3,'a','coffee')");
    expect((await search.search('milk', table: 'docs')).total, 0);
    expect(
        (await search.search('coffee', table: 'docs')).hits.single.documentId,
        '3');
    expect(
        (await db.query(
                'SELECT source_key FROM _sps_1_keys ORDER BY source_key'))
            .rows,
        [
          ['2'],
          ['3']
        ]);
    expect(
        (await db.query('SELECT count(*) FROM _sps_1_fts')).rows.single.single,
        BigInt.two);
    await search.verifyIndex(table: 'docs');
  });

  test(
      'insert/update/delete/key changes synchronize, rollback leaves no changes',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT,price INTEGER)');
    await db.execute("INSERT INTO docs VALUES (1,'milk',1),(2,'tea',2)");
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    await db.execute("UPDATE docs SET body='coffee' WHERE id=1");
    await db.execute("DELETE FROM docs WHERE id=2");
    await db.execute("INSERT INTO docs VALUES (3,'coffee',3)");
    final result = await search.search('coffee', table: 'docs');
    expect(result.hits.map((h) => h.documentId), ['1', '3']);
    expect((await search.search('milk', table: 'docs')).total, 0);
    expect((await db.query('SELECT * FROM _sps_1_pending')).rows, isEmpty);
    await db.execute('UPDATE docs SET price=10');
    expect((await db.query('SELECT * FROM _sps_1_pending')).rows, isEmpty);
    await db.execute('BEGIN');
    await db.execute("INSERT INTO docs VALUES (4,'coffee',4)");
    await db.execute("UPDATE docs SET body='water' WHERE id=1");
    await db.execute('ROLLBACK');
    expect((await search.search('coffee', table: 'docs')).total, 2);
    await db.execute('UPDATE docs SET id=5 WHERE id=1');
    expect(
        (await search.search('coffee', table: 'docs'))
            .hits
            .map((h) => h.documentId),
        ['3', '5']);
  });

  test('pending changes reopen and embedding failure preserves replay log',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id TEXT PRIMARY KEY,body TEXT)');
    await db.execute("INSERT INTO docs VALUES ('a','milk')");
    final provider = FixtureEmbeddingProvider(
        modelId: 'sync-fixture',
        dimensions: 2,
        vectors: {
          'milk': [1, 0],
          'tea': [0, 1]
        });
    final search =
        await SqlitePlusSearch.open(database: db, embeddingProvider: provider);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    await db.execute("UPDATE docs SET body='unknown'");
    await expectLater(search.search('milk', table: 'docs'), throwsStateError);
    expect((await db.query('SELECT * FROM _sps_1_pending')).rows, isNotEmpty);
    await db.execute("UPDATE docs SET body='tea'");
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    final other = await SqlitePlusSearch.open(
        database: reopened, embeddingProvider: provider);
    expect(
        (await other.search('tea', table: 'docs', mode: SearchMode.hybrid))
            .hits
            .single
            .documentId,
        'a');
    expect(
        (await reopened.query('SELECT * FROM _sps_1_pending')).rows, isEmpty);
    await reopened.execute('DROP TRIGGER _sps_1_insert');
    await expectLater(other.search('tea', table: 'docs'), throwsStateError);
  });
}
