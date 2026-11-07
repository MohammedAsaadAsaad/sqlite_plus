import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test('existing search trigger replay coexists without replacing its log',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'docs');
    final c = await feed.consumer(name: 'app');
    await feed.transaction((tx) async {
      await tx.execute("INSERT INTO docs VALUES(1,'milk')");
    });
    expect((await search.search('milk', table: 'docs')).hits.single.documentId,
        '1');
    await feed.transaction((tx) async {
      await tx.execute("UPDATE docs SET body='tea' WHERE id=1");
    });
    expect((await search.search('milk', table: 'docs')).hits, isEmpty);
    expect((await search.search('tea', table: 'docs')).hits.single.documentId,
        '1');
    expect((await c.read()).events.map((e) => e.kind),
        [ChangeKind.insert, ChangeKind.update]);
    await search.verifyIndex(table: 'docs');
  });
}
