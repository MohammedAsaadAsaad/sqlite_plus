import 'dart:math';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test(
      'seeded insert/update/delete/key-change/savepoint replay equals fresh rebuild',
      () async {
    final live = await openInMemory(), reference = await openInMemory();
    addTearDown(live.close);
    addTearDown(reference.close);
    final texts = ['milk حليب', 'tea شاي', 'milk tea', 'water ماء'];
    final provider = FixtureEmbeddingProvider(
        modelId: 'state-fixture-v1',
        dimensions: 2,
        vectors: {
          texts[0]: [1, 0],
          texts[1]: [0, 1],
          texts[2]: [0.7, 0.7],
          texts[3]: [-1, 0],
          'milk': [1, 0]
        });
    for (final db in [live, reference]) {
      await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    }
    final incremental = await SqlitePlusSearch.open(
        database: live, embeddingProvider: provider);
    final rebuilt = await SqlitePlusSearch.open(
        database: reference, embeddingProvider: provider);
    await incremental.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    final expected = <int, String>{};
    final random = Random(41723);
    for (var step = 0; step < 24; step++) {
      final id = 1 + random.nextInt(8),
          text = texts[random.nextInt(texts.length)];
      if (step % 6 == 0) {
        await live.execute('BEGIN');
        await live.execute('SAVEPOINT draft');
        await live
            .execute('INSERT OR REPLACE INTO docs VALUES (?,?)', [id, text]);
        await live.execute('ROLLBACK TO draft');
        await live.execute('RELEASE draft');
        await live.execute('COMMIT');
      } else if (step % 5 == 0 && expected.containsKey(id)) {
        final newId = 100 + step;
        await live.execute('UPDATE docs SET id=? WHERE id=?', [newId, id]);
        expected[newId] = expected.remove(id)!;
      } else if (step % 3 == 0) {
        await live.execute('DELETE FROM docs WHERE id=?', [id]);
        expected.remove(id);
      } else if (expected.containsKey(id)) {
        await live.execute('UPDATE docs SET body=? WHERE id=?', [text, id]);
        expected[id] = text;
      } else {
        await live.execute('INSERT INTO docs VALUES (?,?)', [id, text]);
        expected[id] = text;
      }
      await reference.execute('DELETE FROM docs');
      for (final entry in expected.entries) {
        await reference
            .execute('INSERT INTO docs VALUES (?,?)', [entry.key, entry.value]);
      }
      await rebuilt
          .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
      for (final mode in SearchMode.values) {
        final filter = step.isEven ? SearchFilter('id>=?', [4]) : null;
        final a = await incremental.search('milk',
            table: 'docs', mode: mode, filter: filter, limit: 3, offset: 1);
        final b = await rebuilt.search('milk',
            table: 'docs', mode: mode, filter: filter, limit: 3, offset: 1);
        expect(a.total, b.total, reason: 'step=$step mode=$mode');
        expect(a.hits.map((h) => h.documentId), b.hits.map((h) => h.documentId),
            reason: 'step=$step mode=$mode');
        for (var i = 0; i < a.hits.length; i++) {
          expect(a.hits[i].score, closeTo(b.hits[i].score, 1e-12));
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
