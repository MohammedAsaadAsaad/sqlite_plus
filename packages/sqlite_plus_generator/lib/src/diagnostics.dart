/// An actionable generator failure at a source location.
final class GeneratorDiagnostic {
  const GeneratorDiagnostic(
    this.code,
    this.message,
    this.path,
    this.line,
    this.column, {
    this.offset = 0,
  });

  /// Stable diagnostic code, such as `G010`.
  final String code;

  /// Sentence describing the failure.
  final String message;

  /// Absolute path of the source file.
  final String path;

  /// 1-based line and column of the failure.
  final int line;

  /// 1-based column of the failure.
  final int column;

  /// Zero-based byte offset, when the resolver provided one.
  final int offset;

  @override
  String toString() => '$path:$line:$column: $code: $message';
}

/// All detected model errors. Generation never writes a partial result.
final class GenerationException implements Exception {
  GenerationException(Iterable<GeneratorDiagnostic> diagnostics)
    : diagnostics = List.unmodifiable(diagnostics);

  /// Every diagnostic found before writing was refused.
  final List<GeneratorDiagnostic> diagnostics;

  @override
  String toString() => diagnostics.join('\n');
}

/// A validated, formatted generated part. Building this value does not write.
final class GenerationResult {
  GenerationResult(
    this.inputPath,
    this.outputPath,
    this.code,
    Iterable<String> entityNames,
  ) : entityNames = List.unmodifiable(entityNames);

  /// Absolute path of the library that was read.
  final String inputPath;

  /// Absolute path of the part that would be written.
  final String outputPath;

  /// Formatted Dart source, including the generator header.
  final String code;

  /// Model class names present in [code].
  final List<String> entityNames;
}
