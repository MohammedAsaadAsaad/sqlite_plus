part of '../sqlite_plus_orm.dart';

/// Adapter capability. Fallbacks preserve the adapter pipeline and explicitly
/// report that they do not reuse engine syntax.
abstract class OrmPreparedCommand {
  bool get usesEnginePreparation;
  Future<QueryResult> query(List<Object?> parameters);
  Future<MutationResult> execute(List<Object?> parameters);
  Future<void> close();
}

final class _FallbackPreparedCommand implements OrmPreparedCommand {
  _FallbackPreparedCommand(this.connection, this.sql);
  final OrmConnection connection;
  final String sql;
  bool closed = false;
  @override
  bool get usesEnginePreparation => false;
  void check() {
    if (closed) throw const OrmStateException('Prepared command closed');
  }

  @override
  Future<QueryResult> query(List<Object?> parameters) {
    check();
    return connection.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(List<Object?> parameters) {
    check();
    return connection.execute(sql, parameters);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _EnginePreparedCommand implements OrmPreparedCommand {
  _EnginePreparedCommand(this.connection, this.statement);
  final OrmConnection connection;
  final SqlPreparedStatement statement;
  @override
  bool get usesEnginePreparation => true;
  @override
  Future<QueryResult> query(List<Object?> parameters) {
    connection.inTransaction;
    return statement.query(parameters);
  }

  @override
  Future<MutationResult> execute(List<Object?> parameters) {
    connection.inTransaction;
    return statement.execute(parameters);
  }

  @override
  Future<void> close() => statement.close();
}

final class _ScopedPreparedCommand implements OrmPreparedCommand {
  _ScopedPreparedCommand(this.command, this.scope);
  final OrmPreparedCommand command;
  final OrmOperationRunner scope;
  @override
  bool get usesEnginePreparation => command.usesEnginePreparation;
  @override
  Future<QueryResult> query(List<Object?> parameters) =>
      scope(() => command.query(parameters));
  @override
  Future<MutationResult> execute(List<Object?> parameters) =>
      scope(() => command.execute(parameters));
  @override
  Future<void> close() => command.close();
}

/// Binding identity, not a string substitution. Reuse the same object as a map
/// key. Values are checked by this Dart type and each mapped column's codec.
final class QueryParameter<V> {
  QueryParameter(this.name) {
    if (name.isEmpty || name.length > 128) {
      throw ArgumentError('Parameter name');
    }
  }
  final String name;
  Object? _check(Object? value) => value as V;
}

final class _OrmParameterUse {
  _OrmParameterUse(this.parameter, this.encode);
  final QueryParameter<dynamic> parameter;
  final Object? Function(Object?) encode;
}

final class _ParameterPredicate<T, V> extends SqlPredicate<T> {
  const _ParameterPredicate(this.column, this.operator, this.parameter);
  final Column<T, V> column;
  final String operator;
  final QueryParameter<V> parameter;
  @override
  Iterable<Column<T, dynamic>> get _columns => [column];
  @override
  String _sql(List<Object?> values) {
    values.add(_OrmParameterUse(parameter, (v) => column.encodeValue(v as V)));
    return '${quoteIdentifier(column.sqlName)} $operator ?';
  }
}

extension ParameterColumnPredicates<T, V> on Column<T, V> {
  /// Fixed SQL '=' semantics: a NULL binding does not match NULL. Use isParameter
  /// when null-safe equality is desired.
  SqlPredicate<T> eqParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '=', p);
  SqlPredicate<T> notEqParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '<>', p);
  SqlPredicate<T> gtParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '>', p);
  SqlPredicate<T> gteParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '>=', p);
  SqlPredicate<T> ltParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '<', p);
  SqlPredicate<T> lteParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, '<=', p);
  SqlPredicate<T> isParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, 'IS', p);
  SqlPredicate<T> isNotParameter(QueryParameter<V> p) =>
      _ParameterPredicate(this, 'IS NOT', p);
}

List<Object?> _bindPrepared(
    List<Object?> template, Map<QueryParameter<dynamic>, Object?> parameters) {
  final needed = {
    for (final item in template)
      if (item is _OrmParameterUse) item.parameter
  };
  if (parameters.length != needed.length ||
      !parameters.keys.every(needed.contains)) {
    throw const OrmStateException('Missing or unexpected query parameter');
  }
  return List.unmodifiable(template.map((item) {
    if (item is! _OrmParameterUse) return copyOrmValue(item);
    try {
      return copyOrmValue(
          item.encode(item.parameter._check(parameters[item.parameter])));
    } catch (error) {
      throw OrmCodecException(
          'Invalid binding for ${item.parameter.name}', error);
    }
  }));
}

DbContext _preparedOwner<T>(TypedQuery<T> query) => query._watchOwner;

abstract class _OrmPreparedResource {
  Future<void> _dispose();
}

extension PreparedTypedQueries<T> on TypedQuery<T> {
  Future<PreparedOrmQuery<T>> prepare() {
    final owner = _preparedOwner(this);
    return owner._run(() async {
      registerOrmScalars(connection, [type]);
      final command = _command(template: true);
      final compiled = await connection.prepareCommand(command.sql);
      final result = PreparedOrmQuery<T>._(owner, this, command, compiled);
      (owner._preparedResources ??= {}).add(result);
      return result;
    });
  }

  Future<PreparedOrmUpdate<T>> prepareUpdate(
      Map<Column<T, dynamic>, Object?> values,
      {List<Column<T, dynamic>> returning = const []}) {
    final owner = _preparedOwner(this);
    return owner._run(() async {
      _writeType(type);
      if (_ordering.isNotEmpty ||
          _offset != 0 ||
          _limit != null ||
          _rank ||
          _distance) {
        throw const OrmStateException(
            'Prepared UPDATE cannot combine ordering/pagination/rank');
      }
      if (values.isEmpty) {
        throw const OrmMappingException('UPDATE requires assignments');
      }
      _writeColumns(type, values.keys);
      final selected = _projection(type, returning);
      final parameters = <Object?>[], assignments = <String>[];
      final changed = <Column<T, dynamic>>[];
      for (final entry in values.entries) {
        final column = entry.key, value = entry.value;
        if (column.keyOrder != null || column.generated || column.version) {
          throw const OrmMappingException(
              'Keys/generated/version fields are managed by ORM');
        }
        String expression;
        if (value is _ArithmeticAssignment<T, dynamic>) {
          _writeColumns(type, value._columns);
          expression = value._sql(parameters);
        } else if (value is QueryParameter) {
          parameters.add(_OrmParameterUse(value, column.encodeValue));
          expression = '?';
        } else {
          if (value is SqlExpression) {
            throw const OrmMappingException('Unsupported assignment');
          }
          parameters.add(copyOrmValue(column.encodeValue(value)));
          expression = '?';
        }
        assignments.add('${quoteIdentifier(column.sqlName)}=$expression');
        changed.add(column);
      }
      final version = type.versionColumn;
      if (version != null) {
        assignments.add(
            '${quoteIdentifier(version.sqlName)}=${quoteIdentifier(version.sqlName)}+1');
        changed.add(version);
      }
      final predicate = _predicate?._sql(parameters);
      final projected =
          <Column<T, dynamic>>{...changed, ...selected, ...type.keys}.toList();
      final sql =
          'UPDATE ${quoteIdentifier(type.tableName)} SET ${assignments.join(',')}${predicate == null ? '' : ' WHERE $predicate'} RETURNING ${projected.map((c) => quoteIdentifier(c.sqlName)).join(',')}';
      final command = await connection.prepareCommand(sql);
      final result = PreparedOrmUpdate<T>._(
          owner,
          type,
          List.unmodifiable(parameters
              .map((p) => p is _OrmParameterUse ? p : copyOrmValue(p))),
          projected,
          selected,
          command);
      (owner._preparedResources ??= {}).add(result);
      return result;
    });
  }
}

final class PreparedOrmQuery<T> implements _OrmPreparedResource {
  PreparedOrmQuery._(this.owner, this._query, this._template, this._command);
  final DbContext owner;
  final TypedQuery<T> _query;
  final OrmQueryCommand _template;
  final OrmPreparedCommand _command;
  bool _closed = false;
  bool get isClosed => _closed;
  bool get usesEnginePreparation => _command.usesEnginePreparation;
  Future<List<T>> toList(
      {Map<QueryParameter<dynamic>, Object?> parameters = const {}}) {
    try {
      if (_closed) throw const OrmStateException('Prepared query closed');
      final bound = _bindPrepared(_template._parameters, parameters);
      return owner._run(() async {
        if (_closed) throw const OrmStateException('Prepared query closed');
        final result = await _command.query(bound);
        return [for (final row in result.rows) _query._read(result, row)];
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<void> close() => _closed
      ? Future.value()
      : owner._closed
          ? _dispose()
          : owner._run(_dispose);
  @override
  Future<void> _dispose() async {
    if (_closed) return;
    await _command.close();
    _closed = true;
    owner._preparedResources?.remove(this);
  }
}

final class PreparedOrmUpdate<T> implements _OrmPreparedResource {
  PreparedOrmUpdate._(this.owner, this.type, this._template, this._projected,
      this._selected, this._command);
  final DbContext owner;
  final EntityType<T> type;
  final List<Object?> _template;
  final List<Column<T, dynamic>> _projected, _selected;
  final OrmPreparedCommand _command;
  bool _closed = false;
  bool get isClosed => _closed;
  bool get usesEnginePreparation => _command.usesEnginePreparation;
  Future<OrmWriteResult> execute(
      {Map<QueryParameter<dynamic>, Object?> parameters = const {}}) {
    try {
      if (_closed) throw const OrmStateException('Prepared update closed');
      final bound = _bindPrepared(_template, parameters);
      return owner._directWrite(() async {
        if (_closed) throw const OrmStateException('Prepared update closed');
        final broad = (await owner._triggerTables())
                .contains(type.tableName.toLowerCase()) ||
            owner.model.foreignKeys.isNotEmpty;
        final mutation = await _command.execute(bound);
        final rows = await owner
            ._writeRows(type, mutation, _projected, _selected, broad: broad);
        return OrmWriteResult._(mutation.changes, rows);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<void> close() => _closed
      ? Future.value()
      : owner._closed
          ? _dispose()
          : owner._run(_dispose);
  @override
  Future<void> _dispose() async {
    if (_closed) return;
    await _command.close();
    _closed = true;
    owner._preparedResources?.remove(this);
  }
}
