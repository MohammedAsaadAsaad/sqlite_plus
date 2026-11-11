part of '../sqlite_plus_orm.dart';

/// A SQLite connection the ORM can query, write, and close.
abstract class OrmConnection {
  Object? _owner;

  /// Optional same-isolate engine capability; null for RPC/custom connections.
  MutableSqliteDatabase? get engineDatabase => null;
  SqlitePlusChanges? get changeFeed => null;
  bool get usesSaveTransactionDriver => false;

  /// Adapters must opt in explicitly so wrappers never lose capture/inspection.
  bool get supportsEnginePreparation => false;
  Future<OrmPreparedCommand> prepareCommand(String sql) async {
    if (!supportsEnginePreparation) return _FallbackPreparedCommand(this, sql);
    // Also checks closed/connection lease through the adapter's normal property.
    inTransaction;
    try {
      return _EnginePreparedCommand(this, await engineDatabase!.prepare(sql));
    } on UnsupportedError {
      return _FallbackPreparedCommand(this, sql);
    }
  }

  Future<R> exclusive<R>(Future<R> Function() action,
          {bool schemaChange = false}) =>
      action();

  /// Own a complete save transaction. Adapters may replace the BEGIN/COMMIT
  /// path, while preserving callback ordering and rolling back failed work.
  Future<void> transaction(Future<void> Function() action,
      {void Function()? onCommitting}) async {
    if (inTransaction) {
      throw const OrmStateException('Transaction already active');
    }
    await execute('BEGIN');
    try {
      await action();
      onCommitting?.call();
      await execute('COMMIT');
    } catch (error, stack) {
      try {
        if (inTransaction) await execute('ROLLBACK');
      } catch (cleanup) {
        Error.throwWithStackTrace(
            OrmStateException('Transaction failed and rollback also failed',
                (operation: error, rollback: cleanup)),
            stack);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Runs a statement that returns rows.
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]);

  /// Runs a statement that changes rows.
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]);

  /// Whether this connection has an open transaction.
  bool get inTransaction;

  /// Closes the connection. The owner must already have released it.
  Future<void> close();

  /// Gives [owner] exclusive use of this connection.
  void claim(Object owner) {
    if (_owner != null) {
      if (identical(_owner, owner)) return;
      throw const OrmStateException('Connection already belongs to a context');
    }
    _claim(owner);
    _owner = owner;
  }

  /// Drops the claim held by [owner].
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

/// ORM connection over one file owner opened by [DbSet.openDbFile].
final class _OrmFileConnection extends OrmConnection {
  _OrmFileConnection(this._handle);
  final OrmFileHandle _handle;

  @override
  bool get inTransaction => _handle.inTransaction();

  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _handle.query(sql, parameters);

  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _handle.execute(sql, parameters);

  @override
  Future<void> close() => _handle.close();
}

/// ORM connection over a [MutableSqliteDatabase].
final class MutableDatabaseConnection extends OrmConnection {
  /// Uses [database]. Closes it on [close] only when [closeDatabase] is true.
  MutableDatabaseConnection(this.database, {this.closeDatabase = false});

  /// Opens an in-memory engine database and closes it with this connection.
  static Future<MutableDatabaseConnection> openMemory() async =>
      MutableDatabaseConnection(await MutableSqliteDatabase.create(),
          closeDatabase: true);

  /// Engine database this connection forwards to.
  final MutableSqliteDatabase database;
  @override
  MutableSqliteDatabase get engineDatabase => database;
  @override
  bool get supportsEnginePreparation => true;

  /// Whether [close] also closes [database].
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

/// ORM connection over a browser or memory [OpenedStorage].
///
/// Save and query use [MutableSqliteDatabase]. Close writes the image through
/// the public storage backend. [StorageCapabilities.durabilityPromised] stays
/// false for this path, including after a successful reopen.
final class BrowserDatabaseConnection extends OrmConnection {
  BrowserDatabaseConnection._(this.storage, this.capabilities, this.database);

  /// Byte store holding the database image.
  final StorageBackend storage;

  /// Capabilities reported when the store was opened.
  final StorageCapabilities capabilities;

  /// In-memory engine loaded from [storage].
  final MutableSqliteDatabase database;
  @override
  MutableSqliteDatabase get engineDatabase => database;
  @override
  bool get supportsEnginePreparation => true;
  bool _closed = false;

  /// Loads [opened] into a memory database, or creates one when it is empty.
  static Future<BrowserDatabaseConnection> open(OpenedStorage opened) async {
    requireWritable(opened.capabilities);
    final length = await opened.storage.length();
    final MutableSqliteDatabase database;
    if (length == 0) {
      database = await MutableSqliteDatabase.create();
    } else {
      final bytes = Uint8List(length);
      final read = await opened.storage.read(0, bytes);
      if (read != length) {
        throw const OrmStateException('Browser image read was short');
      }
      database = await MutableSqliteDatabase.fromImage(bytes);
    }
    return BrowserDatabaseConnection._(
        opened.storage, opened.capabilities, database);
  }

  void _check() {
    if (_closed) throw const OrmStateException('Connection is closed');
  }

  /// Writes the current image back to [storage].
  Future<void> flush() async {
    _check();
    requireWritable(capabilities);
    if (database.inTransaction) {
      throw const OrmStateException(
          'Commit or roll back before flushing browser storage');
    }
    final image = database.exportImage();
    await storage.truncate(0);
    await storage.write(0, image);
    await storage.sync();
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
    await flush();
    await database.close();
    await storage.close();
    _closed = true;
  }
}

/// Optional transaction bridge shared with Changes/Sync. Query reads outside a
/// scope also queue on Changes, so they cannot interleave a foreign writer.
final class ChangesOrmConnection extends OrmConnection {
  ChangesOrmConnection(this.delegate, this.changes) {
    if (!identical(delegate.engineDatabase, changes.database)) {
      throw const OrmStateException(
          'Changes requires the same exposed engine connection');
    }
  }
  final OrmConnection delegate;
  final SqlitePlusChanges changes;
  final _writerZone = Object(), _rawZone = Object();
  ChangeWriter? get _writer => Zone.current[_writerZone] as ChangeWriter?;
  bool get _raw => Zone.current[_rawZone] == true;
  @override
  MutableSqliteDatabase? get engineDatabase => delegate.engineDatabase;
  @override
  SqlitePlusChanges get changeFeed => changes;
  @override
  bool get usesSaveTransactionDriver => true;
  @override
  bool get inTransaction => _writer != null || _raw && delegate.inTransaction;
  @override
  void _claim(Object owner) => delegate.claim(owner);
  @override
  void _release(Object owner) => delegate.release(owner);
  @override
  Future<R> exclusive<R>(Future<R> Function() action,
      {bool schemaChange = false}) {
    if (_raw) return action();
    if (_writer != null) {
      throw const OrmStateException('Schema scope cannot join a captured save');
    }
    return changes.exclusive(
        (_) => runZoned(action, zoneValues: {_rawZone: true}),
        notifyReset: schemaChange);
  }

  @override
  Future<void> transaction(Future<void> Function() action,
      {void Function()? onCommitting}) async {
    if (inTransaction) {
      throw const OrmStateException('Transaction already active');
    }
    await changes.transaction((tx) => runZoned(() async {
          await action();
          onCommitting?.call();
        }, zoneValues: {_writerZone: tx}));
  }

  @override
  Future<OrmPreparedCommand> prepareCommand(String sql) async {
    // Writes must go through ChangeWriter.execute; never execute directly on db.
    if (SqlTokenizer.tokenize(sql).first.keyword != 'SELECT') {
      return _FallbackPreparedCommand(this, sql);
    }
    Future<R> scope<R>(Future<R> Function() action) =>
        _writer != null || _raw ? action() : changes.exclusive((_) => action());
    final command = await scope(() => delegate.prepareCommand(sql));
    return _ScopedPreparedCommand(command, scope);
  }

  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    final writer = _writer;
    if (writer != null) return writer.query(sql, parameters);
    if (_raw) return delegate.query(sql, parameters);
    return changes.exclusive((_) => delegate.query(sql, parameters));
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    final writer = _writer;
    if (writer != null) return writer.execute(sql, parameters);
    if (_raw) return delegate.execute(sql, parameters);
    final head = SqlTokenizer.tokenize(sql).firstOrNull?.keyword;
    if ({'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'WITH'}.contains(head)) {
      return changes.transaction((tx) => tx.execute(sql, parameters));
    }
    if ({'BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'SAVEPOINT', 'RELEASE'}
        .contains(head)) {
      throw const OrmStateException(
          'Use transaction/exclusive on a Changes-backed connection');
    }
    return changes.exclusive((_) => delegate.execute(sql, parameters));
  }

  @override
  Future<void> close() => delegate.close();
}
