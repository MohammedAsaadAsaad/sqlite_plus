import 'package:sqlite_plus/sqlite_plus.dart' show SqlException;
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

/// An application-supplied local embedding model. Implementations must never
/// download models or contact network services during inference.
abstract interface class LocalEmbeddingProvider {
  /// Stable identity including model revision and preprocessing version.
  String get modelId;

  /// Output dimensions, from 1 through 4096.
  int get dimensions;

  /// Embeds one document or query using an already provisioned local model.
  Future<List<double>> embed(String text);
}

/// Calls a local provider and validates the vector before float32 storage.
///
/// Zero vectors have no cosine direction and are rejected. The provider contract
/// is a trust boundary: Dart cannot sandbox arbitrary application provider code.
Future<List<double>> validatedEmbedding(
    LocalEmbeddingProvider provider, String text) async {
  final modelId = provider.modelId;
  final dimensions = provider.dimensions;
  if (modelId.trim().isEmpty || dimensions < 1 || dimensions > 4096) {
    throw ArgumentError('Invalid embedding model identity or dimensions');
  }
  final vector = List<double>.of(await provider.embed(text));
  if (provider.modelId != modelId || provider.dimensions != dimensions) {
    throw StateError('Embedding provider identity changed during inference');
  }
  if (vector.length != dimensions ||
      vector.any((value) => !value.isFinite) ||
      vector.every((value) => value == 0)) {
    throw ArgumentError(
        'Embedding must be finite, nonzero and match dimensions');
  }
  // Validate float32 representability too: a finite double can overflow float32.
  final List<double> stored;
  try {
    stored = decodeVec(encodeVec(vector));
  } on SqlException {
    throw ArgumentError('Embedding overflows float32');
  }
  if (stored.every((value) => value == 0)) {
    throw ArgumentError('Embedding underflows float32');
  }
  return List<double>.unmodifiable(stored);
}

/// Exact input-to-vector lookup for deterministic plumbing tests only.
///
/// This provider has no semantic understanding, generalization or trained model.
/// Unknown inputs fail instead of silently substituting keyword search.
final class FixtureEmbeddingProvider implements LocalEmbeddingProvider {
  FixtureEmbeddingProvider({
    required this.modelId,
    required this.dimensions,
    required Map<String, List<double>> vectors,
  }) : _vectors = Map.unmodifiable(vectors.map(
            (key, value) => MapEntry(key, List<double>.unmodifiable(value))));

  @override
  final String modelId;
  @override
  final int dimensions;
  final Map<String, List<double>> _vectors;

  @override
  Future<List<double>> embed(String text) async {
    final vector = _vectors[text];
    if (vector == null) throw StateError('No fixture embedding for input');
    return vector;
  }
}
