part of 'mutable_database.dart';

extension PreparedSqlDatabase on MutableSqliteDatabase {
  /// Compile connection-bound reusable syntax. Does not execute the statement.
  /// Simple ordinary SELECT and unqualified ordinary DML targets are supported.
  Future<SqlPreparedStatement> prepare(String sql) => _exclusive(() async {
        final syntax = SqlPreparation(sql);
        final kind = syntax.tokens.first.keyword;
        if (!const {'SELECT', 'INSERT', 'REPLACE', 'UPDATE', 'DELETE'}
            .contains(kind)) {
          throw UnsupportedError(
              'prepare supports SELECT/INSERT/UPDATE/DELETE/REPLACE');
        }
        final result = SqlPreparedStatement._(this, sql, kind == 'SELECT');
        await result._compile();
        return result;
      });
}

/// Reusable syntax with fresh values/rows on each call. One in-flight operation
/// per handle; close explicitly. It never owns/closes the database.
final class SqlPreparedStatement {
  SqlPreparedStatement._(this._database, this.sql, this.isReadOnly);
  MutableSqliteDatabase? _database;
  final String sql;
  final bool isReadOnly;
  SqlPreparation? _program;
  StatementRoute? _route;
  String? _reportedTarget;
  int _epoch = -1, _preparations = 0;
  int _lastExpressionParses = 0, _lastExpressionHits = 0, _lastSelectParses = 0;
  bool _busy = false;
  bool get isClosed => _database == null;
  int get parameterCount => _program?.parameterCount ?? _parameterCount;
  int _parameterCount = 0;
  int get preparationCount => _preparations;
  int get expressionParseCount =>
      _program?.expressionParses ?? _lastExpressionParses;
  int get expressionReuseCount =>
      _program?.expressionHits ?? _lastExpressionHits;
  int get selectParseCount => _program?.selectParses ?? _lastSelectParses;

  Future<void> _ensureCurrent() async {
    if (_database == null) throw StateError('Prepared statement is closed');
    if (_epoch != _database!._preparationEpoch) await _compile();
  }

  Future<void> _compile() async {
    final db = _database!;
    final names = await db._schemaCatalog();
    final route =
        isReadOnly ? routeQuery(sql, names) : routeMutation(sql, names);
    if (route.cross || !isReadOnly && route.kind != 'single') {
      throw UnsupportedError('Cross-schema preparation is not supported');
    }
    final program =
        _program?.sql == route.sql ? _program! : SqlPreparation(route.sql);
    program.resetSyntax();
    if (route.schema == 'main') db._materializeMain();
    final ownsReader = route.schema != 'main';
    final reader = ownsReader
        ? await SqliteDatabase.openReadOnly(
            ByteImageStorage(db._imageFor(route.schema!)),
            functions: db.functions)
        : await db._cachedMainReader();
    try {
      if (isReadOnly) {
        reader.validatePreparation(program);
      } else {
        final p = SqlParser.prepared(program);
        final replace = p.take('REPLACE');
        final insert = replace || p.take('INSERT');
        final update = !insert && p.take('UPDATE');
        if (!insert && !update) p.require('DELETE');
        if (!replace && (insert || update) && p.take('OR')) p.identifier();
        if (insert) p.require('INTO');
        if (!insert && !update) p.require('FROM');
        final target = p.identifier();
        if (p.current.text == '.') {
          throw UnsupportedError('Prepared DML targets must be unqualified');
        }
        final table = reader.catalog.table(target);
        if (table.virtual ||
            reader.catalog.entries.any((e) =>
                asciiLower(e.name) == asciiLower(target) && e.type == 'view')) {
          throw UnsupportedError('Prepared DML requires an ordinary table');
        }
        final state = route.schema == 'main' && db._liveMain != null
            ? db._liveMain!
            : await ImageMutations.load(db._imageFor(route.schema!));
        final wrote = state.wroteRows;
        try {
          await state.execute(
              route.sql, List.filled(program.parameterCount, null),
              compileOnly: true,
              foreignKeys: db._foreignKeys,
              inTransaction: db.inTransaction,
              preparation: program);
        } finally {
          state.wroteRows = wrote;
        }
      }
    } finally {
      if (ownsReader) await reader.close();
    }
    _reportedTarget = isReadOnly ? null : qualifiedDmlTarget(sql);
    _route = route;
    _program = program;
    _parameterCount = program.parameterCount;
    _epoch = db._preparationEpoch;
    _preparations++;
  }

  Future<T> _operation<T>(List<Object?> parameters, bool read,
      Future<T> Function(MutableSqliteDatabase, List<Object?>) run) {
    try {
      if (isClosed) throw StateError('Prepared statement is closed');
      if (_busy) throw StateError('Prepared statement is already executing');
      if (read != isReadOnly) {
        throw StateError('Use query for SELECT and execute for DML');
      }
      if (parameters.length != parameterCount) {
        throw const SqlException('Incorrect parameter count');
      }
      final bound = List<Object?>.unmodifiable(parameters.map(sqlValue));
      _busy = true;
      return run(_database!, bound).whenComplete(() => _busy = false);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<QueryResult> query([List<Object?> parameters = const []]) =>
      _operation(
          parameters,
          true,
          (db, bound) => db._exclusive(() async {
                await _ensureCurrent();
                return db._queryUnlocked(sql, bound, this);
              }));
  Future<MutationResult> execute([List<Object?> parameters = const []]) =>
      _operation(parameters, false,
          (db, bound) => db._executeStatement(sql, bound, prepared: this));
  Future<void> close() {
    if (_busy) {
      return Future.error(StateError('Cannot close an executing statement'));
    }
    _lastExpressionParses = expressionParseCount;
    _lastExpressionHits = expressionReuseCount;
    _lastSelectParses = selectParseCount;
    _database = null;
    _route = null;
    _program = null;
    return Future.value();
  }
}
