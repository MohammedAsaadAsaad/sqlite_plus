import 'package:sqlite_plus/sqlite_plus.dart';

/// File connection operations opened outside the browser-safe library.
final class OrmFileHandle {
  /// [query], [execute], [inTransaction], and [close] talk to one file owner.
  OrmFileHandle({
    required this.query,
    required this.execute,
    required this.inTransaction,
    required this.close,
  });

  /// Runs a statement that returns rows.
  final Future<QueryResult> Function(String sql, List<Object?> parameters)
      query;

  /// Runs a statement that changes rows.
  final Future<MutationResult> Function(String sql, List<Object?> parameters)
      execute;

  /// Whether this client owns an open transaction.
  final bool Function() inTransaction;

  /// Closes the file owner.
  final Future<void> Function() close;
}
