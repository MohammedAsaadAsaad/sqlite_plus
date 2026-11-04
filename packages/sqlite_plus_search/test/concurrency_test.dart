import 'dart:async';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

final class GatedProvider implements LocalEmbeddingProvider {
  final entered = Completer<void>(), release = Completer<void>();
  bool first = true;
  @override
  String get modelId => 'gated-v1';
  @override
  int get dimensions => 2;
  @override
  Future<List<double>> embed(String text) async {
    if (first) {
      first = false;
      entered.complete();
      await release.future;
      return [double.nan, 0];
    }
    return [1, 0];
  }
}

void main() {
  test(
      'handles share a queue; provider failure rolls back and unblocks later work; databases remain independent',
      () async {
    final db = await openInMemory(), independent = await openInMemory();
    addTearDown(db.close);
    addTearDown(independent.close);
    await db.execute("CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)");
    await db.execute("INSERT INTO docs VALUES (1,'milk')");
    await independent
        .execute("CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)");
    final provider = GatedProvider();
    final first =
        await SqlitePlusSearch.open(database: db, embeddingProvider: provider);
    final second =
        await SqlitePlusSearch.open(database: db, embeddingProvider: provider);
    final other = await SqlitePlusSearch.open(database: independent);
    final failing = first
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final expectedFailure = expectLater(failing, throwsArgumentError);
    await provider.entered.future;
    var queuedCompleted = false;
    final queued = second.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body']).then((_) => queuedCompleted = true);
    try {
      await other.indexTable(
          table: 'docs',
          primaryKey: 'id',
          textColumns: ['body']).timeout(const Duration(seconds: 5));
      expect(queuedCompleted, isFalse);
    } finally {
      provider.release.complete();
    }
    await expectedFailure;
    await queued;
    final results = await Future.wait(List.generate(
        24, (i) => (i.isEven ? first : second).search('milk', table: 'docs')));
    expect(results.every((result) => result.hits.single.documentId == '1'),
        isTrue);
    expect(results.map((result) => result.searchId).toSet().length, 24);
    expect(
        (await db.query('SELECT count(*) FROM _sps_collections'))
            .rows
            .single
            .single,
        BigInt.one);
    expect(db.inTransaction, isFalse);
  });
}
