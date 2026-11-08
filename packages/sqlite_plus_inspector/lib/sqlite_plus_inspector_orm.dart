/// Optional ORM adapter. Wrap Changes before inspection, using [ormConnection].
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'sqlite_plus_inspector.dart';

export 'sqlite_plus_inspector.dart';

final class InspectedOrmConnection extends OrmConnection {
  InspectedOrmConnection(this.delegate, this.inspector, {String label = 'orm'})
      : identity = inspector.connection(label) {
    if (delegate is InspectedOrmConnection &&
        identical((delegate as InspectedOrmConnection).inspector, inspector)) {
      throw ArgumentError('Connection already inspected by this collector');
    }
  }
  final OrmConnection delegate;
  final SqlInspector inspector;
  final InspectorConnection identity;
  @override
  MutableSqliteDatabase? get engineDatabase => delegate.engineDatabase;
  @override
  SqlitePlusChanges? get changeFeed => delegate.changeFeed;
  @override
  bool get usesSaveTransactionDriver => delegate.usesSaveTransactionDriver;
  @override
  bool get inTransaction => delegate.inTransaction;
  @override
  void claim(Object owner) {
    delegate.claim(owner);
    try {
      super.claim(owner);
    } catch (_) {
      delegate.release(owner);
      rethrow;
    }
  }

  @override
  void release(Object owner) {
    super.release(owner);
    delegate.release(owner);
  }

  @override
  Future<R> exclusive<R>(Future<R> Function() action,
          {bool schemaChange = false}) =>
      delegate.exclusive(action, schemaChange: schemaChange);
  @override
  Future<void> transaction(Future<void> Function() action,
          {void Function()? onCommitting}) =>
      delegate.transaction(action, onCommitting: onCommitting);
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      inspector.measure(sql, parameters, InspectorOperation.query,
          () => delegate.query(sql, parameters),
          connection: identity, rows: (r) => r.rows.length);
  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      inspector.measure(sql, parameters, InspectorOperation.execute,
          () => delegate.execute(sql, parameters),
          connection: identity,
          rows: (r) => r.returning?.rows.length,
          affectedRows: (r) => r.changes);

  /// Call while the context is idle. RPC handles have no snapshot capability.
  Future<InspectorPlan> explain(String sql,
          [List<Object?> parameters = const []]) async =>
      await delegate.exclusive(() {
        final database = delegate.engineDatabase;
        if (database == null) {
          throw UnsupportedError(
              'No main-image plan capability on this ORM connection');
        }
        return inspectDatabasePlan(database, sql, parameters);
      });
  @override
  Future<void> close() => delegate.close();
}

extension SqlInspectorOrm on SqlInspector {
  /// Changes wrapping is inside inspection, so captured SQL is observable.
  InspectedOrmConnection ormConnection(OrmConnection connection,
      {SqlitePlusChanges? changes, String label = 'orm'}) {
    if (connection is InspectedOrmConnection &&
        identical(connection.inspector, this)) {
      throw ArgumentError('Connection already inspected by this collector');
    }
    return InspectedOrmConnection(
        changes == null
            ? connection
            : ChangesOrmConnection(connection, changes),
        this,
        label: label);
  }
}
