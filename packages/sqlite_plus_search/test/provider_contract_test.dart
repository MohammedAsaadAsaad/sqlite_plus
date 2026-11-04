import 'dart:async';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

final class MutableProvider implements LocalEmbeddingProvider {
  @override
  String modelId = 'mutable-v1';
  @override
  int dimensions = 2;
  final entered = Completer<void>(), release = Completer<void>();
  final Object? failure;
  MutableProvider({this.failure});
  @override
  Future<List<double>> embed(String text) async {
    entered.complete();
    await release.future;
    if (failure != null) throw failure!;
    return [1, 0];
  }
}

void main() {
  for (final field in ['identity', 'dimensions']) {
    test('reject changing provider $field during inference', () async {
      final provider = MutableProvider();
      final pending = validatedEmbedding(provider, 'milk');
      final expected = expectLater(
          pending,
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('identity changed'))));
      await provider.entered.future;
      if (field == 'identity') {
        provider.modelId = 'v2';
      } else {
        provider.dimensions = 3;
      }
      provider.release.complete();
      await expected;
    });
  }
  test('provider failure propagates unchanged, never becomes keyword fallback',
      () async {
    final failure = StateError('local model unavailable');
    final provider = MutableProvider(failure: failure);
    final pending = validatedEmbedding(provider, 'milk');
    final expected = expectLater(pending, throwsA(same(failure)));
    await provider.entered.future;
    provider.release.complete();
    await expected;
  });
  test(
      'invalid empty-collection provider metadata fails before writing search schema',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    for (final dimensions in [0, 4097]) {
      final provider = FixtureEmbeddingProvider(
          modelId: 'empty-fixture', dimensions: dimensions, vectors: {});
      await expectLater(
          SqlitePlusSearch.open(database: db, embeddingProvider: provider),
          throwsArgumentError);
    }
    expect(
        (await db.query("SELECT name FROM sqlite_schema WHERE type='table'"))
            .rows,
        isEmpty);
  });
}
