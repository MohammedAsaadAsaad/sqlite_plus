import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';
import 'package:test/test.dart';

void main() {
  FixtureEmbeddingProvider provider(List<double> vector,
          {int dimensions = 2, String id = 'fixture-v1'}) =>
      FixtureEmbeddingProvider(
          modelId: id, dimensions: dimensions, vectors: {'milk': vector});

  test('local fixture validates and integrates with existing vector distance',
      () async {
    final vector = await validatedEmbedding(provider([1, 0]), 'milk');
    expect(vecDistance(vector, [1, 0], 'cosine'), 0);
    expect(vecDistance(vector, [0, 1], 'cosine'), 1);
    expect(() => vector[0] = 3, throwsUnsupportedError);
  });

  test('fixture copies caller data and rejects unknown input', () async {
    final source = [1.0, 0.0];
    final model = provider(source);
    source[0] = 0;
    expect(await validatedEmbedding(model, 'milk'), [1, 0]);
    await expectLater(model.embed('unknown'), throwsStateError);
  });

  test('rejects malformed output and invalid metadata', () async {
    for (final vector in <List<double>>[
      [],
      [1],
      [0, 0],
      [double.nan, 1],
      [double.infinity, 1],
      [1e100, 1],
      [1e-100, 0]
    ]) {
      await expectLater(
          validatedEmbedding(provider(vector), 'milk'), throwsArgumentError);
    }
    for (final dimensions in [0, -1, 4097]) {
      await expectLater(
          validatedEmbedding(provider([1, 0], dimensions: dimensions), 'milk'),
          throwsArgumentError);
    }
    await expectLater(validatedEmbedding(provider([1, 0], id: ' '), 'milk'),
        throwsArgumentError);
  });
}
