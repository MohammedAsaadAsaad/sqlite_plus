import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';
import 'package:test/test.dart';

void main() {
  for (final corruption in [
    'mapping',
    'zero vector',
    'short vector',
    'missing FTS row',
    'FTS block',
    'FTS index',
    'metadata',
    'same-named trigger'
  ]) {
    test('detect and explicitly rebuild after $corruption corruption',
        () async {
      final db = await openInMemory();
      addTearDown(db.close);
      await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
      await db.execute("INSERT INTO docs VALUES (1,'milk'),(2,'tea')");
      final search = await SqlitePlusSearch.open(
          database: db,
          embeddingProvider: FixtureEmbeddingProvider(
              modelId: 'corruption-fixture-v1',
              dimensions: 2,
              vectors: {
                'milk': [1, 0],
                'tea': [0, 1]
              }));
      Future<void> rebuild() => search.indexTable(
          table: 'docs',
          primaryKey: 'id',
          textColumns: ['body'],
          autoUpdate: true);
      await rebuild();
      await search.verifyIndex(table: 'docs');
      switch (corruption) {
        case 'mapping':
          await db.execute(
              "UPDATE _sps_1_keys SET source_key='missing' WHERE id=1");
        case 'zero vector':
          await db
              .execute('UPDATE _sps_1_vec_vec SET embedding=? WHERE rowid=1', [
            encodeVec([0, 0])
          ]);
        case 'short vector':
          await db.execute(
              'UPDATE _sps_1_vec_vec SET embedding=? WHERE rowid=1',
              [Uint8List(1)]);
        case 'missing FTS row':
          await db.execute('DELETE FROM _sps_1_fts WHERE rowid=1');
        case 'FTS block':
          await db
              .execute("UPDATE _sps_1_fts_data SET block=x'00' WHERE id>100");
        case 'FTS index':
          await db.execute('DELETE FROM _sps_1_fts_idx');
        case 'metadata':
          await db.execute(
              "UPDATE _sps_collections SET text_columns='invalid json'");
        case 'same-named trigger':
          await db.execute('DROP TRIGGER _sps_1_insert');
          await db.execute(
              'CREATE TRIGGER _sps_1_insert AFTER INSERT ON docs BEGIN SELECT 1; END');
      }
      await expectLater(search.verifyIndex(table: 'docs'), throwsStateError);
      if (corruption == 'zero vector' || corruption == 'short vector') {
        await expectLater(
            search.search('milk', table: 'docs', mode: SearchMode.semantic),
            throwsStateError);
      }
      await rebuild();
      await search.verifyIndex(table: 'docs');
      expect(
          (await search.search('milk', table: 'docs', mode: SearchMode.hybrid))
              .hits
              .first
              .documentId,
          '1');
      expect((await db.query('SELECT body FROM docs ORDER BY id')).rows, [
        ['milk'],
        ['tea']
      ]);
    });
  }
  test(
      'pending edits are not corruption; successful replay refreshes the integrity baseline',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    await db.execute("INSERT INTO docs VALUES (1,'milk')");
    await search.verifyIndex(table: 'docs');
    expect((await search.search('milk', table: 'docs')).hits.single.documentId,
        '1');
    await search.verifyIndex(table: 'docs');
  });
}
