part of 'search.dart';

/// Explicit relevance label for one returned document.
enum Relevance { low, high }

/// Small local linear reranker over reciprocal keyword/vector ranks.
final class AdaptiveLearningConfig {
  const AdaptiveLearningConfig({this.enabled = false, this.learningRate = 0.2});
  final bool enabled;
  final double learningRate;
}

/// Local feedback and versioned collection-specific model management.
final class SearchFeedback {
  SearchFeedback._(this._search);
  final SqlitePlusSearch _search;

  /// Each returned search/document pair can be labeled only once. Contexts are
  /// bounded to the latest 1000 returned hits across collections in this DB.
  Future<void> submit(
          {required String searchId,
          required String documentId,
          required Relevance relevance}) =>
      _search._run(() => _search._transaction(() async {
            if (!_search.learning.enabled) {
              throw StateError('Learning is disabled');
            }
            final db = _search.database;
            final result = await db.query(
                'SELECT id,collection_id,f_keyword,f_vector,used FROM _sps_feedback NOT INDEXED WHERE search_id=? AND document_id=?',
                [searchId, documentId]);
            if (result.rows.length != 1 ||
                result.rows.single[4] != BigInt.zero) {
              throw StateError(
                  'Unknown, expired or already labeled feedback context');
            }
            final row = result.rows.single;
            final collection = row[1].toString();
            final weights = await _search._weights(collection);
            final features = [
              (row[2] as num).toDouble(),
              (row[3] as num).toDouble()
            ];
            final prediction = 1 /
                (1 +
                    math.exp(-(weights[0] * features[0] +
                        weights[1] * features[1])));
            final error =
                (relevance == Relevance.high ? 1.0 : 0.0) - prediction;
            final updated = [
              for (var i = 0; i < 2; i++)
                (weights[i] +
                        _search.learning.learningRate * error * features[i])
                    .clamp(-1.0, 1.0)
            ];
            await _search._saveWeights(collection, updated);
            await db.execute(
                'UPDATE _sps_feedback SET used=1 WHERE id=?', [row[0]]);
          }));

  Future<void> reset({required String table}) =>
      _search._run(() => _search._transaction(() async {
            final meta = await _search._metadata(table);
            await _search._saveWeights(meta.id, [0, 0]);
            await _search.database.execute(
                'DELETE FROM _sps_feedback WHERE collection_id=?',
                [BigInt.parse(meta.id)]);
          }));

  Future<Map<String, Object>> exportModel({required String table}) =>
      _search._run(() async {
        final meta = await _search._metadata(table);
        return Map.unmodifiable({
          'version': 1,
          'collection': table,
          'analyzer': meta.analyzer,
          'modelId': meta.modelId ?? '',
          'dimensions': meta.dimensions ?? 0,
          'weights': List<double>.unmodifiable(await _search._weights(meta.id))
        });
      });

  Future<void> importModel(
          {required String table, required Map<String, Object?> model}) =>
      _search._run(() => _search._transaction(() async {
            final meta = await _search._metadata(table);
            final weights = model['weights'];
            if (model['version'] != 1 ||
                model['collection'] != table ||
                model['analyzer'] != meta.analyzer ||
                model['modelId'] != (meta.modelId ?? '') ||
                model['dimensions'] != (meta.dimensions ?? 0) ||
                weights is! List ||
                weights.length != 2 ||
                weights.any((w) =>
                    w is! num || !w.toDouble().isFinite || w.abs() > 1)) {
              throw ArgumentError('Incompatible or malformed ranking model');
            }
            await _search._saveWeights(
                meta.id, weights.cast<num>().map((w) => w.toDouble()).toList());
            await _search.database.execute(
                'DELETE FROM _sps_feedback WHERE collection_id=?',
                [BigInt.parse(meta.id)]);
          }));
}
