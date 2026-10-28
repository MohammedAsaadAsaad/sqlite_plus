part of '../sqlite_plus_orm.dart';

/// A SQLite connection the ORM can query, write, and close.
abstract class OrmConnection {
  Object? _owner;

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
