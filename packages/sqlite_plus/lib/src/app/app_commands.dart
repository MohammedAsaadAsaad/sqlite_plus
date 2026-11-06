import 'dart:typed_data';

import '../sql/database.dart';
import '../sql/mutable_database.dart';
import '../sql/tokenizer.dart';

/// How an `INSERT` or `UPDATE` behaves when a constraint fails.
enum ConflictAlgorithm {
  /// `OR ROLLBACK`.
  rollback('OR ROLLBACK'),

  /// `OR ABORT`.
  abort('OR ABORT'),

  /// `OR FAIL`.
  fail('OR FAIL'),

  /// `OR IGNORE`.
  ignore('OR IGNORE'),

  /// `OR REPLACE`.
  replace('OR REPLACE');

  const ConflictAlgorithm(this._sql);
  final String _sql;
}

/// Table helpers over one SQL connection.
///
/// Integers in rows and insert ids are [BigInt]. An `int` argument is stored
/// as an integer. A `List<int>` argument is stored as a blob. SQL errors are
/// [SqlException].
final class AppCommands {
  /// [query] and [execute] run one statement. [inTransaction] reports the
  /// connection. [isOpen] is false after the owner closes.
  AppCommands({
    required Future<QueryResult> Function(String sql, List<Object?> parameters)
        query,
    required Future<MutationResult> Function(
            String sql, List<Object?> parameters)
        execute,
    required bool Function() inTransaction,
    required bool Function() isOpen,
  })  : _queryFn = query,
        _executeFn = execute,
        _inTransaction = inTransaction,
        _isOpen = isOpen;

  final Future<QueryResult> Function(String sql, List<Object?> parameters)
      _queryFn;
  final Future<MutationResult> Function(String sql, List<Object?> parameters)
      _executeFn;
  final bool Function() _inTransaction;
  final bool Function() _isOpen;
  var _depth = 0;

  /// Runs SQL that does not need its result.
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await _execute(sql, arguments);
  }

  /// Runs one statement and returns the rows as maps.
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) async =>
      _maps(await _query(sql, arguments));

  /// Runs one insert and returns its row id.
  Future<BigInt> rawInsert(String sql, [List<Object?>? arguments]) async =>
      (await _execute(sql, arguments)).lastInsertRowid ?? BigInt.zero;

  /// Runs one update and returns the changed-row count.
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async =>
      (await _execute(sql, arguments)).changes;

  /// Runs one delete and returns the changed-row count.
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async =>
      (await _execute(sql, arguments)).changes;

  /// Inserts [values] and returns the new row id.
  ///
  /// An empty [values] map inserts NULL into [nullColumnHack].
  Future<BigInt> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    final names = <String>[];
    final arguments = <Object?>[];
    values.forEach((name, value) {
      names.add(_sqlName(name));
      arguments.add(_argument(value));
    });
    if (names.isEmpty) {
      if (nullColumnHack == null || nullColumnHack.isEmpty) {
        throw ArgumentError('nullColumnHack is required for an empty insert');
      }
      names.add(_sqlName(nullColumnHack));
      arguments.add(null);
    }
    final conflict =
        conflictAlgorithm == null ? '' : ' ${conflictAlgorithm._sql}';
    return rawInsert(
      'INSERT$conflict INTO ${_sqlName(table)} (${names.join(', ')}) '
      'VALUES (${List.filled(arguments.length, '?').join(', ')})',
      arguments,
    );
  }

  /// Reads [table]. [where] is SQL, and its values belong in [whereArgs].
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    if (limit != null && limit < 0) {
      throw ArgumentError.value(limit, 'limit');
    }
    if (offset != null && offset < 0) {
      throw ArgumentError.value(offset, 'offset');
    }
    final selected = columns == null
        ? '*'
        : columns.isEmpty
            ? throw ArgumentError('columns is empty')
            : columns.map(_sqlName).join(', ');
    final sql = StringBuffer('SELECT ');
    if (distinct ?? false) sql.write('DISTINCT ');
    sql
      ..write(selected)
      ..write(' FROM ')
      ..write(_sqlName(table));
    if (where != null) sql.write(' WHERE $where');
    if (groupBy != null) sql.write(' GROUP BY $groupBy');
    if (having != null) sql.write(' HAVING $having');
    if (orderBy != null) sql.write(' ORDER BY $orderBy');
    if (limit != null || offset != null) {
      sql.write(' LIMIT ${limit ?? -1}');
      if (offset != null) sql.write(' OFFSET $offset');
    }
    return rawQuery(sql.toString(), whereArgs);
  }

  /// Updates the rows selected by [where] and returns the changed-row count.
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    if (values.isEmpty) throw ArgumentError('values is empty');
    final assignments = <String>[];
    final arguments = <Object?>[];
    values.forEach((name, value) {
      assignments.add('${_sqlName(name)} = ?');
      arguments.add(_argument(value));
    });
    arguments.addAll((whereArgs ?? const <Object?>[]).map(_argument));
    final conflict =
        conflictAlgorithm == null ? '' : ' ${conflictAlgorithm._sql}';
    final sql = StringBuffer(
        'UPDATE$conflict ${_sqlName(table)} SET ${assignments.join(', ')}');
    if (where != null) sql.write(' WHERE $where');
    return rawUpdate(sql.toString(), arguments);
  }

  /// Deletes the rows selected by [where] and returns the changed-row count.
  Future<int> delete(String table,
      {String? where, List<Object?>? whereArgs}) async {
    final sql = StringBuffer('DELETE FROM ${_sqlName(table)}');
    if (where != null) sql.write(' WHERE $where');
    return rawDelete(sql.toString(), whereArgs);
  }

  /// Runs [action] in a transaction. A nested call uses a savepoint.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    _ensureOpen();
    final nested = _depth > 0;
    final name = 'sp$_depth';
    if (nested) {
      await _execute('SAVEPOINT $name');
    } else {
      await _execute('BEGIN');
    }
    _depth++;
    try {
      final result = await action(Transaction._(this));
      if (nested) {
        await _execute('RELEASE $name');
      } else {
        await _execute('COMMIT');
      }
      return result;
    } catch (_) {
      if (_inTransaction()) {
        if (nested) {
          await _execute('ROLLBACK TO $name');
          await _execute('RELEASE $name');
        } else {
          await _execute('ROLLBACK');
        }
      }
      rethrow;
    } finally {
      _depth--;
    }
  }

  /// Collects statements and runs them in [Batch.commit].
  Batch batch() {
    _ensureOpen();
    return Batch._(this);
  }

  /// Reads `PRAGMA user_version` as an int.
  Future<int> readUserVersion() async {
    final rows = await rawQuery('PRAGMA user_version');
    final value = rows.single.values.single;
    if (value is BigInt) return value.toInt();
    if (value is int) return value;
    throw StateError('user_version is $value');
  }

  Future<QueryResult> _query(String sql, [List<Object?>? arguments]) {
    _ensureOpen();
    return _queryFn(sql, _arguments(arguments));
  }

  Future<MutationResult> _execute(String sql, [List<Object?>? arguments]) {
    _ensureOpen();
    return _executeFn(sql, _arguments(arguments));
  }

  void _ensureOpen() {
    if (!_isOpen()) throw StateError('Database closed');
  }
}

/// One transaction callback. Its statements use the surrounding connection.
final class Transaction {
  Transaction._(this._commands);
  final AppCommands _commands;

  /// Runs SQL that does not need its result.
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _commands.execute(sql, arguments);

  /// Runs one statement and returns the rows as maps.
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      _commands.rawQuery(sql, arguments);

  /// Runs one insert and returns its row id.
  Future<BigInt> rawInsert(String sql, [List<Object?>? arguments]) =>
      _commands.rawInsert(sql, arguments);

  /// Runs one update and returns the changed-row count.
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _commands.rawUpdate(sql, arguments);

  /// Runs one delete and returns the changed-row count.
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _commands.rawDelete(sql, arguments);

  /// Inserts [values] and returns the new row id.
  Future<BigInt> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _commands.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  /// Reads [table].
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _commands.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  /// Updates the rows selected by [where].
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      _commands.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);

  /// Deletes the rows selected by [where].
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _commands.delete(table, where: where, whereArgs: whereArgs);

  /// Runs [action] in a savepoint inside this transaction.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) =>
      _commands.transaction(action);

  /// Collects statements and runs them in [Batch.commit].
  Batch batch() => _commands.batch();
}

/// Statements collected for one [commit].
final class Batch {
  Batch._(this._commands);
  final AppCommands _commands;
  final List<Future<Object?> Function(Transaction txn)> _operations = [];

  /// Queues an insert.
  void insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) {
    _operations.add((txn) => txn.insert(table, values,
        nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm));
  }

  /// Queues [Transaction.rawInsert].
  void rawInsert(String sql, [List<Object?>? arguments]) {
    _operations.add((txn) => txn.rawInsert(sql, arguments));
  }

  /// Queues an update.
  void update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) {
    _operations.add((txn) => txn.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm));
  }

  /// Queues [Transaction.rawUpdate].
  void rawUpdate(String sql, [List<Object?>? arguments]) {
    _operations.add((txn) => txn.rawUpdate(sql, arguments));
  }

  /// Queues a delete.
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    _operations
        .add((txn) => txn.delete(table, where: where, whereArgs: whereArgs));
  }

  /// Queues [Transaction.rawDelete].
  void rawDelete(String sql, [List<Object?>? arguments]) {
    _operations.add((txn) => txn.rawDelete(sql, arguments));
  }

  /// Queues a table query.
  void query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    _operations.add((txn) => txn.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset));
  }

  /// Queues [Transaction.rawQuery].
  void rawQuery(String sql, [List<Object?>? arguments]) {
    _operations.add((txn) => txn.rawQuery(sql, arguments));
  }

  /// Queues [Transaction.execute]. The result slot is null.
  void execute(String sql, [List<Object?>? arguments]) {
    _operations.add((txn) async {
      await txn.execute(sql, arguments);
      return null;
    });
  }

  /// Runs the queued statements.
  ///
  /// [exclusive] wraps them in one transaction and defaults to true. A SQL
  /// error rolls that transaction back unless [continueOnError] is true, in
  /// which case the slot holds the [SqlException]. [noResult] returns an empty
  /// list after the statements run.
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    final keepGoing = continueOnError ?? false;
    Future<List<Object?>> run(Transaction txn) async {
      final results = <Object?>[];
      for (final operation in _operations) {
        try {
          results.add(await operation(txn));
        } on SqlException catch (error) {
          if (!keepGoing) rethrow;
          results.add(error);
        }
      }
      if (noResult ?? false) return const [];
      return results;
    }

    if (exclusive ?? true) return _commands.transaction(run);
    return run(Transaction._(_commands));
  }
}

List<Map<String, Object?>> _maps(QueryResult result) => [
      for (final row in result.rows)
        {
          for (var index = 0; index < result.columns.length; index++)
            result.columns[index]: row[index]
        }
    ];

List<Object?> _arguments(List<Object?>? arguments) =>
    [for (final value in arguments ?? const <Object?>[]) _argument(value)];

Object? _argument(Object? value) {
  if (value is List<int> && value is! Uint8List) {
    return Uint8List.fromList(value);
  }
  return value;
}

String _sqlName(String name) {
  if (name.isEmpty || name.contains('\u0000')) {
    throw ArgumentError.value(name, 'name', 'Empty SQL name');
  }
  return '"${name.replaceAll('"', '""')}"';
}
