part of '../sqlite_plus_orm.dart';

abstract class OrmConnection {
  Object? _owner;
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]);
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]);
  bool get inTransaction;
  Future<void> close();

  void claim(Object owner) {
    if (_owner != null) {
      if (identical(_owner, owner)) return;
      throw const OrmStateException('Connection already belongs to a context');
    }
    _claim(owner);
    _owner = owner;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) {
      throw const OrmStateException(
          'Only the owning context may release a connection');
    }
    _release(owner);
    _owner = null;
  }

  void _claim(Object owner) {}
  void _release(Object owner) {}
}

final class MutableDatabaseConnection extends OrmConnection {
  MutableDatabaseConnection(this.database, {this.closeDatabase = false});
  final MutableSqliteDatabase database;
  final bool closeDatabase;
  bool _closed = false;
  static final _leases = Expando<MutableDatabaseConnection>();

  void _check() {
    if (_closed) throw const OrmStateException('Connection is closed');
    final lease = _leases[database];
    if (lease != null && !identical(lease, this)) {
      throw const OrmStateException('Database belongs to another connection');
    }
  }

  @override
  void _claim(Object owner) {
    _check();
    _leases[database] = this;
  }

  @override
  void _release(Object owner) {
    if (identical(_leases[database], this)) _leases[database] = null;
  }

  @override
  bool get inTransaction {
    _check();
    return database.inTransaction;
  }

  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    _check();
    return database.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    _check();
    return database.execute(sql, parameters);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_owner != null) {
      throw const OrmStateException(
          'Release the context before closing its connection');
    }
    if (closeDatabase) {
      _check();
      await database.close();
    }
    _closed = true;
  }
}
