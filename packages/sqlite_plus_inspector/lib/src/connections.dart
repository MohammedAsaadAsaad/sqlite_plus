part of '../sqlite_plus_inspector.dart';

typedef InspectorQueryRunner = Future<QueryResult> Function(
    String, List<Object?>);
typedef InspectorExecuteRunner = Future<MutationResult> Function(
    String, List<Object?>);
typedef InspectorPlanRunner = Future<InspectorPlan> Function(
    String, List<Object?>);
typedef InspectorDiagnosticRunner = Future<SqlQueryDiagnostics> Function(
    String, List<Object?>, SqlDiagnosticOptions);

void _selectOnly(String sql) {
  final head = SqlTokenizer.tokenize(sql).firstOrNull?.keyword;
  if (head != 'SELECT' && head != 'WITH') {
    throw ArgumentError('Plan inspection accepts SELECT queries only');
  }
}

/// Explicit main-image snapshot planning. Does not run the original SELECT.
Future<InspectorPlan> inspectDatabasePlan(
    MutableSqliteDatabase database, String sql,
    [List<Object?> parameters = const []]) async {
  _selectOnly(sql);
  return _inspectSnapshot(
      database, (reader) => InspectorPlan._(reader.explain(sql, parameters)));
}

/// Explicit private-image diagnosis of one routed schema. Routing/image/open
/// preparation are outside the core report timing, but inside profile()'s
/// inspector record. The source connection stays exclusively loaned during SQL
/// callbacks; ordinary query() is never replaced by this diagnostic operation.
Future<SqlQueryDiagnostics> inspectDatabaseQuery(
    MutableSqliteDatabase database, String sql,
    {List<Object?> parameters = const [],
    SqlDiagnosticOptions options = const SqlDiagnosticOptions()}) async {
  _selectOnly(sql);
  return database.diagnoseQuery(sql, parameters: parameters, options: options);
}

Future<T> _inspectSnapshot<T>(MutableSqliteDatabase database,
    FutureOr<T> Function(SqliteDatabase) read) async {
  final image = database.exportImage();
  final storage = MemoryStorageBackend();
  await storage.write(0, image);
  SqliteDatabase? reader;
  try {
    reader = await SqliteDatabase.openReadOnly(storage,
        functions: database.functions);
    reader.doubleQuotedStrings = database.doubleQuotedStrings;
    return await read(reader);
  } finally {
    if (reader != null) {
      await reader.close();
    } else {
      await storage.close();
    }
  }
}

/// Explicit runner adapter. Calls made directly on the original engine bypass it.
final class InspectedConnection {
  InspectedConnection(
      {required this.inspector,
      required InspectorQueryRunner query,
      InspectorExecuteRunner? execute,
      Future<void> Function()? close,
      bool Function()? inTransaction,
      InspectorPlanRunner? plan,
      InspectorDiagnosticRunner? diagnostic,
      String label = 'database'})
      : _query = query,
        _execute = execute,
        _close = close,
        _inTransaction = inTransaction,
        _plan = plan,
        _diagnostic = diagnostic,
        identity = inspector.connection(label);
  factory InspectedConnection.mutable(
          MutableSqliteDatabase database, SqlInspector inspector,
          {String label = 'database'}) =>
      InspectedConnection(
          inspector: inspector,
          query: database.query,
          execute: database.execute,
          close: database.close,
          inTransaction: () => database.inTransaction,
          plan: (sql, args) => inspectDatabasePlan(database, sql, args),
          diagnostic: (sql, args, options) => inspectDatabaseQuery(
              database, sql,
              parameters: args, options: options),
          label: label);
  factory InspectedConnection.readOnly(
          SqliteDatabase database, SqlInspector inspector,
          {String label = 'read-only'}) =>
      InspectedConnection(
          inspector: inspector,
          query: database.query,
          close: database.close,
          plan: (sql, args) async {
            _selectOnly(sql);
            return InspectorPlan._(database.explain(sql, args));
          },
          diagnostic: (sql, args, options) =>
              database.diagnoseQuery(sql, parameters: args, options: options),
          label: label);
  final SqlInspector inspector;
  final InspectorConnection identity;
  final InspectorQueryRunner _query;
  final InspectorExecuteRunner? _execute;
  final Future<void> Function()? _close;
  final bool Function()? _inTransaction;
  final InspectorPlanRunner? _plan;
  final InspectorDiagnosticRunner? _diagnostic;
  bool get inTransaction => _inTransaction?.call() ?? false;
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      inspector.measure(sql, parameters, InspectorOperation.query,
          () => _query(sql, parameters),
          connection: identity, rows: (r) => r.rows.length);
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    final execute = _execute;
    if (execute == null) {
      return Future.error(UnsupportedError('Read-only inspected connection'));
    }
    return inspector.measure(sql, parameters, InspectorOperation.execute,
        () => execute(sql, parameters),
        connection: identity,
        rows: (r) => r.returning?.rows.length,
        affectedRows: (r) => r.changes);
  }

  Future<InspectorPlan> explain(String sql,
      [List<Object?> parameters = const []]) {
    final plan = _plan;
    if (plan == null) {
      return Future.error(
          UnsupportedError('No plan capability on this adapter'));
    }
    return plan(sql, parameters);
  }

  /// Explicit diagnostic capability; normal query() never enables it.
  Future<SqlQueryDiagnostics> profile(String sql,
      {List<Object?> parameters = const [],
      SqlDiagnosticOptions options = const SqlDiagnosticOptions()}) {
    final diagnostic = _diagnostic;
    if (diagnostic == null) {
      return Future.error(
          UnsupportedError('No diagnostic capability on this adapter'));
    }
    return inspector.measure(sql, parameters, InspectorOperation.query,
        () => diagnostic(sql, parameters, options),
        connection: identity, rows: (r) => r.result.rows.length);
  }

  Future<SqlPage<Map<String, Object?>>> page(
          {required String table,
          required List<String> keyColumns,
          List<PageOrder> orderBy = const [],
          List<String>? columns,
          String? where,
          List<Object?> parameters = const [],
          int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      SqlPagination(query).page(
          table: table,
          keyColumns: keyColumns,
          orderBy: orderBy,
          columns: columns,
          where: where,
          parameters: parameters,
          size: size,
          after: after,
          before: before,
          cursorScope: cursorScope);

  /// Delegates ownership to the supplied close callback; does not close collector.
  Future<void> close() async {
    await _close?.call();
  }
}

extension SqlInspectorConnections on SqlInspector {
  InspectedConnection database(MutableSqliteDatabase database,
          {String label = 'database'}) =>
      InspectedConnection.mutable(database, this, label: label);
  InspectedConnection readOnly(SqliteDatabase database,
          {String label = 'read-only'}) =>
      InspectedConnection.readOnly(database, this, label: label);
}
