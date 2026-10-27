/// An actionable generator failure at a source location.
final class GeneratorDiagnostic {
  const GeneratorDiagnostic(
      this.code, this.message, this.path, this.line, this.column,
      {this.offset = 0});

  final String code;
  final String message;
  final String path;
  final int line;
  final int column;
  final int offset;

  @override
  String toString() => '$path:$line:$column: $code: $message';
}

/// All detected model errors. Generation never writes a partial result.
final class GenerationException implements Exception {
  GenerationException(Iterable<GeneratorDiagnostic> diagnostics)
      : diagnostics = List.unmodifiable(diagnostics);

  final List<GeneratorDiagnostic> diagnostics;

  @override
  String toString() => diagnostics.join('\n');
}

/// A validated, formatted generated part. Building this value does not write.
final class GenerationResult {
  GenerationResult(
      this.inputPath, this.outputPath, this.code, Iterable<String> entityNames)
      : entityNames = List.unmodifiable(entityNames);

  final String inputPath;
  final String outputPath;
  final String code;
  final List<String> entityNames;
}
