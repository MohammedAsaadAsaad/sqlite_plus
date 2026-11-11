part of 'mutable_database.dart';

extension SqlMutableReadDiagnostics on MutableSqliteDatabase {
  /// Explicit diagnosis on a private image of the single routed schema.
  /// Holds the normal connection exclusion while SQL callbacks execute, so
  /// temp shadowing/schema routing and reentrant-write rejection are preserved.
  /// Routing/image preparation/opening are outside the inner reader timings.
  Future<SqlQueryDiagnostics> diagnoseQuery(String sql,
      {List<Object?> parameters = const [],
      SqlDiagnosticOptions options = const SqlDiagnosticOptions()}) {
    try {
      if (options.maxCandidates < 0 || options.maxCandidates > 256) {
        throw ArgumentError('maxCandidates must be 0..256');
      }
      if (sql.length > 65536) {
        throw UnsupportedError('Diagnostic SQL exceeds 65536 code units');
      }
      final bound = List<Object?>.unmodifiable(parameters.map(sqlValue));
      return _exclusive(() async {
        final route = routeQuery(sql, await _schemaCatalog());
        if (route.cross || route.schema == null) {
          throw UnsupportedError('Diagnosis requires one routed schema');
        }
        if (route.schema == 'main') _materializeMain();
        final reader = await SqliteDatabase.openReadOnly(
            ByteImageStorage(_imageFor(route.schema!)),
            functions: functions);
        try {
          return await reader.diagnoseQuery(route.sql,
              parameters: bound, options: options);
        } finally {
          await reader.close();
        }
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}
