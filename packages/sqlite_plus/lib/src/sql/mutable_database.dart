import 'dart:async';
import 'dart:typed_data';

import '../btree/database_image_builder.dart';
import 'image_mutations.dart';
import '../pager/image_pager.dart';
import '../storage/memory_storage_backend.dart';
import 'database.dart';
import 'parser.dart';
import 'schema_router.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'function_registry.dart';
import 'virtual_table.dart';

final _crossQueryKey = Object();

final class _ConnectionSnapshot {
  _ConnectionSnapshot(this.main, this.temp, Map<String, Uint8List> attached,
      [this.logical])
      : attached = {
          for (final entry in attached.entries)
            entry.key: Uint8List.fromList(entry.value)
        };
  final Uint8List main;
  final Uint8List temp;
  final Map<String, Uint8List> attached;
  final LogicalImage? logical;
}

/// Outcome of one `INSERT`, `UPDATE`, or `DELETE`.
final class MutationResult {
  /// [changes] is the changed-row count. [lastInsertRowid] is set for an insert.
  const MutationResult(this.changes, this.lastInsertRowid, [this.returning]);

  /// Rows from `RETURNING`, or null when the statement has no returning clause.
  final QueryResult? returning;

  /// Rows changed by this statement.
  final int changes;

  /// Rowid of the last insert in this statement, or null for other statements.
  final BigInt? lastInsertRowid;
}

/// Serialized image mutations with constraints, secondary indexes and row triggers.
/// In-memory by default; an ImagePager supplies the durable commit boundary.
/// Transactions and savepoints retain independent image snapshots.
final class MutableSqliteDatabase {
  MutableSqliteDatabase._(this._image, this._journal);
  Uint8List _image;
  Uint8List _temp = DatabaseImageBuilder.empty();
  final Map<String, Uint8List> _attached = {};
  bool _tempUsed = false;
  final ImagePager? _journal;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;
  bool _foreignKeys = false;
  bool _recursiveTriggers = false;
  int _cacheSize = -2000;
  int _busyTimeout = 0;
  int _synchronous = 2;

  /// Reads ATTACH file paths. Memory ATTACH does not use it. A missing reader
  /// rejects file paths. The bytes are a connection-local copy, not a second journal.
  Future<Uint8List> Function(String path)? attachFile;

  /// Scalar, aggregate, and collation callbacks for this connection.
  final functions = SqlFunctionRegistry();
  _ConnectionSnapshot? _checkpoint;
  bool _explicitTransaction = false;
  final List<(String, _ConnectionSnapshot)> _savepoints = [];
  ImageMutations? _liveMain;
  Uint8List? _liveMainImage;

  /// Live rows include commits whose byte image has not been rebuilt yet.
  bool _dirtyMain = false;
  SchemaNames? _catalog;
  SqliteDatabase? _mainReader;
  Uint8List? _mainReaderImage;

  /// Whether `BEGIN` or a savepoint is open on this connection.
  bool get inTransaction => _checkpoint != null;

  /// Creates an empty in-memory database.
  static Future<MutableSqliteDatabase> create(
          {int pageSize = 4096, int encoding = 1}) =>
      fromImage(
          DatabaseImageBuilder.empty(pageSize: pageSize, encoding: encoding));

  /// Reopens a database from [exportImage] bytes.
  static Future<MutableSqliteDatabase> fromImage(Uint8List image) async {
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final database = await SqliteDatabase.openReadOnly(storage);
    await database.close();
    return MutableSqliteDatabase._(Uint8List.fromList(image), null);
  }

  /// Opens a database whose commits go through [pager].
  static Future<MutableSqliteDatabase> fromJournalPager(
          ImagePager pager) async =>
      MutableSqliteDatabase._(await pager.readImage(), pager);

  /// Opens a database on an [ImagePager].
  static Future<MutableSqliteDatabase> fromImagePager(ImagePager pager) =>
      fromJournalPager(pager);

  /// Copies the current database image. Safe to retain after later writes.
  Uint8List exportImage() {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    _materializeMain();
    return Uint8List.fromList(_image);
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    _busy = true;
    try {
      return await runZoned(() => functions.run(operation), zoneValues: {
        schemaNamesKey: {for (final name in _schemaOrder()) name},
      });
    } finally {
      _busy = false;
    }
  }

  List<String> _schemaOrder() => ['temp', 'main', ..._attached.keys];

  Uint8List _imageFor(String schema) {
    if (schema == 'main') return _image;
    if (schema == 'temp') return _temp;
    final attached = _attached[schema];
    if (attached == null) throw SqlException('Unknown database: $schema');
    return attached;
  }

  void _storeImage(String schema, Uint8List image) {
    final copy = Uint8List.fromList(image);
    if (schema == 'main') {
      _image = copy;
      _dropLive();
      _dropReader();
    } else if (schema == 'temp') {
      _temp = copy;
      _tempUsed = true;
    } else {
      _attached[schema] = copy;
    }
  }

  void _dropLive() {
    _liveMain = null;
    _liveMainImage = null;
    _dirtyMain = false;
  }

  /// Rebuilds the main byte image from live rows. Schema-only reads can skip
  /// this while [schemaChanged] is false; the names in the previous image
  /// still match.
  void _materializeMain() {
    final state = _liveMain;
    if (!_dirtyMain || state == null) return;
    final image = state.serialize(foreignKeys: false, includeDeferred: false);
    _storeImage('main', image);
    state.rebase(_image);
    _liveMain = state;
    _liveMainImage = _image;
    _dirtyMain = false;
  }

  void _dropReader() {
    final reader = _mainReader;
    _mainReader = null;
    _mainReaderImage = null;
    if (reader != null) unawaited(reader.close());
  }

  void _invalidateCatalog() => _catalog = null;

  void _rememberSchema(String sql) {
    final parser = SqlParser(sql);
    if (parser.take('EXPLAIN') || parser.take('WITH')) return;
    final keyword = parser.current.keyword;
    if (keyword == 'CREATE' ||
        keyword == 'DROP' ||
        keyword == 'ALTER' ||
        keyword == 'ANALYZE') {
      _invalidateCatalog();
    }
  }

  Future<SqliteDatabase> _cachedMainReader() async {
    if (_mainReader != null && identical(_mainReaderImage, _image)) {
      return _mainReader!;
    }
    final previous = _mainReader;
    final reader = await SqliteDatabase.openReadOnly(ByteImageStorage(_image),
        functions: functions);
    _mainReader = reader;
    _mainReaderImage = _image;
    if (previous != null) unawaited(previous.close());
    return reader;
  }

  _ConnectionSnapshot _snapshot() => _ConnectionSnapshot(
      _image,
      _temp,
      _attached,
      _dirtyMain && _liveMain != null ? _liveMain!.captureLogical() : null);

  void _restoreSnapshot(_ConnectionSnapshot snapshot) {
    _image = Uint8List.fromList(snapshot.main);
    _temp = Uint8List.fromList(snapshot.temp);
    _attached
      ..clear()
      ..addAll({
        for (final entry in snapshot.attached.entries)
          entry.key: Uint8List.fromList(entry.value)
      });
    _dropReader();
    _invalidateCatalog();
    final logical = snapshot.logical;
    final state = _liveMain;
    if (logical != null && state != null) {
      state.restoreLogical(logical);
      state.rebase(_image);
      _liveMainImage = _image;
      _dirtyMain = true;
    } else {
      _dropLive();
    }
  }

  Future<SchemaNames> _schemaCatalog() async {
    if (_dirtyMain && (_liveMain?.schemaChanged ?? false)) _materializeMain();
    final cached = _catalog;
    if (cached != null) return cached;
    final order = _schemaOrder();
    final tables = <String, Set<String>>{};
    final objects = <String, Set<String>>{};
    for (final schema in order) {
      final ownsReader = schema != 'main';
      final reader = schema == 'main'
          ? await _cachedMainReader()
          : await SqliteDatabase.openReadOnly(
              ByteImageStorage(_imageFor(schema)),
              functions: functions);
      try {
        final rows = await reader.query('SELECT type, name FROM sqlite_schema');
        tables[schema] = {};
        objects[schema] = {};
        for (final row in rows.rows) {
          final name = asciiLower(row[1] as String);
          objects[schema]!.add(name);
          if (row[0] == 'table' || row[0] == 'view') tables[schema]!.add(name);
        }
      } finally {
        if (ownsReader) await reader.close();
      }
    }
    return _catalog = SchemaNames(tables, objects, order);
  }

  Future<QueryResult> _readImage(String schema, String sql,
      [List<Object?> parameters = const [], bool schemaView = false]) async {
    if (schema == 'main' &&
        _dirtyMain &&
        (!schemaView || (_liveMain?.schemaChanged ?? false))) {
      _materializeMain();
    }
    if (schema == 'main') {
      final reader = await _cachedMainReader();
      return reader.query(sql, parameters);
    }
    final reader = await SqliteDatabase.openReadOnly(
        ByteImageStorage(_imageFor(schema)),
        functions: functions);
    try {
      return await reader.query(sql, parameters);
    } finally {
      await reader.close();
    }
  }

  /// Runs one SQL statement and returns its rows.
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final live = _liveMain;
        if (live != null) {
          final fast = live.tryFastRead(sql, parameters);
          if (fast != null) return fast;
        }
        final explain = SqlParser(sql);
        if (explain.take('EXPLAIN')) {
          if (!(explain.take('QUERY') && explain.take('PLAN'))) {
            throw const SqlException('EXPLAIN bytecode is not implemented');
          }
          if (parameters.isNotEmpty) {
            throw const SqlException('EXPLAIN QUERY PLAN bindings unsupported');
          }
          final inner = sql.substring(explain.current.offset);
          final route = routeQuery(inner, await _schemaCatalog());
          if (route.cross) {
            throw const SqlException(
                'cross-database EXPLAIN QUERY PLAN is not implemented');
          }
          if (route.schema == 'main' && _dirtyMain) _materializeMain();
          final reader = await SqliteDatabase.openReadOnly(
              ByteImageStorage(_imageFor(route.schema!)),
              functions: functions);
          try {
            final lines = reader.describeQueryPlan(route.sql);
            return QueryResult([
              'detail'
            ], [
              for (final line in lines) [line]
            ]);
          } finally {
            await reader.close();
          }
        }
        final pragma = SqlParser(sql);
        if (pragma.take('PRAGMA')) {
          return _queryPragma(pragma, sql, parameters);
        }
        final route = routeQuery(sql, await _schemaCatalog());
        if (route.cross) {
          if (Zone.current[_crossQueryKey] == true) {
            throw const SqlException(
                'cross-database query could not be assembled');
          }
          return runZoned(() => _crossQuery(route, parameters),
              zoneValues: {_crossQueryKey: true});
        }
        const schemaTables = {
          'sqlite_schema',
          'sqlite_master',
          'sqlite_temp_schema'
        };
        final schemaView = route.uses
            .every((use) => schemaTables.contains(asciiLower(use.table)));
        return _readImage(route.schema!, route.sql, parameters, schemaView);
      });

  /// Runs one write statement inside the connection lock.
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    final live = _liveMain;
    if (live != null) {
      _busy = true;
      try {
        live.wroteRows = false;
        final hot = live.tryHotDml(sql, parameters,
            foreignKeys: _foreignKeys,
            inTransaction: inTransaction,
            counters: functions.connectionState);
        if (hot != null) {
          if (live.releaseFreedPages) {
            live.releaseFreedPages = false;
            final image = await live.releaseFreedPagesImage();
            if (image != null) {
              // _commitSchema drops the live rows; put them back on the
              // freelist image so the next statement does not compact it.
              await _commitSchema('main', image);
              live.rebase(_image);
              _liveMain = live;
              _liveMainImage = _image;
              _dirtyMain = false;
            } else if (live.wroteRows) {
              _dirtyMain = true;
            }
          } else if (live.wroteRows) {
            _dirtyMain = true;
          }
          // A file-backed autocommit must reach the pager before the
          // statement returns. Hot changes otherwise stay in memory, and
          // close() does not write them.
          final journal = _journal;
          if (journal != null && !inTransaction && _dirtyMain) {
            final state = _liveMain;
            if (state != null) {
              final image = state.serialize(
                foreignKeys: false,
                includeDeferred: false,
              );
              try {
                await journal.commitImage(image);
              } catch (_) {
                _failed = true;
                rethrow;
              }
              _storeImage('main', image);
              state.rebase(_image);
              _liveMain = state;
              _liveMainImage = _image;
              _dirtyMain = false;
            }
          }
          return MutationResult(hot.changes, hot.lastRowid, hot.returning);
        }
      } finally {
        _busy = false;
      }
    }
    return _exclusive(() async {
      final parser = SqlParser(sql);
      if (parser.take('PRAGMA')) {
        final parsed = _pragmaName(parser);
        final name = parsed.$2;
        const writable = {
          'foreign_keys',
          'recursive_triggers',
          'user_version',
          'application_id',
          'cache_size',
          'busy_timeout',
          'synchronous',
          'journal_mode',
          'auto_vacuum'
        };
        if (!writable.contains(name)) {
          throw const SqlException('Unsupported writable PRAGMA');
        }
        final statePragma =
            name == 'foreign_keys' || name == 'recursive_triggers';
        final value = _pragmaValue(parser,
            onParsed: statePragma
                ? (value) => _applyConnectionPragma(name, value, parsed.$1)
                : null);
        if (parameters.isNotEmpty) {
          throw const SqlException('PRAGMA bindings unsupported');
        }
        if (name == 'user_version' || name == 'application_id') {
          if (parsed.$1 == 'main') _materializeMain();
          final signed = _pragmaInteger(value);
          final image = Uint8List.fromList(_imageFor(parsed.$1));
          final fields = ByteData.sublistView(image);
          fields.setInt32(name == 'user_version' ? 60 : 68, signed);
          final counter = (fields.getUint32(24) + 1) & 0xffffffff;
          fields.setUint32(24, counter);
          fields.setUint32(92, counter);
          await _commitSchema(parsed.$1, image);
        } else if (!statePragma) {
          _applyConnectionPragma(name, value, parsed.$1);
        }
        return const MutationResult(0, null);
      }
      if (['BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'SAVEPOINT', 'RELEASE']
          .contains(parser.current.keyword)) {
        if (parameters.isNotEmpty) {
          throw const SqlException('Transaction statements take no parameters');
        }
        return _transaction(parser);
      }
      final route = routeMutation(sql, await _schemaCatalog());
      if (route.kind == 'attach') {
        await _attach(route.name!, route.argument!);
        return const MutationResult(0, null);
      }
      if (route.kind == 'detach') {
        _detach(route.name!);
        return const MutationResult(0, null);
      }
      final schema = route.schema!;
      final keyword = SqlParser(route.sql).current.keyword;
      final maintenance =
          const {'REINDEX', 'ANALYZE', 'VACUUM'}.contains(keyword);
      final vacuumOnLive =
          keyword == 'VACUUM' && schema == 'main' && _liveMain != null;
      if (schema == 'main' && maintenance && !vacuumOnLive) {
        // Maintenance rebuilds from the byte image and resolves functions
        // again. Publish deferred rows, then load that image fresh.
        // VACUUM can renumber the live rows and leave a clean image for the
        // next read when the current image has no free pages.
        _materializeMain();
        _dropLive();
      }
      final current = _imageFor(schema);
      final reuse = schema == 'main' &&
          (!maintenance || vacuumOnLive) &&
          _liveMain != null &&
          (_dirtyMain || identical(_liveMainImage, current) || vacuumOnLive);
      final state = reuse ? _liveMain! : await ImageMutations.load(current);
      final captured = schema == 'main' && reuse && _dirtyMain
          ? state.captureLogical()
          : null;
      state.deferMaterialize =
          schema == 'main' && _journal == null && !maintenance;
      final MutationImage result;
      try {
        result = await state.execute(route.sql, parameters,
            foreignKeys: _foreignKeys,
            inTransaction: inTransaction,
            recursiveTriggers: _recursiveTriggers);
      } on MutationFailure catch (failure) {
        if (failure.rollbackTransaction) {
          if (inTransaction) {
            _restoreSnapshot(_checkpoint!);
            _clearTransaction();
          } else if (captured != null) {
            state.restoreLogical(captured);
            _liveMain = state;
            _dirtyMain = true;
          } else if (schema == 'main') {
            _dropLive();
          }
        } else if (failure.partialImage != null) {
          await _commitSchema(schema, failure.partialImage!);
          if (schema == 'main') _invalidateCatalog();
        } else if (captured != null) {
          state.restoreLogical(captured);
          _liveMain = state;
          _dirtyMain = true;
        } else if (schema == 'main') {
          _dropLive();
        }
        throw failure.error;
      } catch (error) {
        if (captured != null) {
          state.restoreLogical(captured);
          _liveMain = state;
          _dirtyMain = true;
        } else if (schema == 'main') {
          _dropLive();
        }
        rethrow;
      }
      if (!identical(result.image, current)) {
        await _commitSchema(schema, result.image);
      }
      if (schema == 'main') {
        if (!identical(result.image, current)) {
          state.rebase(_image);
          _liveMain = state;
          _liveMainImage = _image;
          _dirtyMain = false;
        } else if (state.wroteRows) {
          _liveMain = state;
          _liveMainImage = _image;
          _dirtyMain = true;
        } else {
          _liveMain = state;
          _liveMainImage = _image;
        }
      }
      _rememberSchema(sql);
      return MutationResult(result.changes, result.lastRowid, result.returning);
    });
  }

  String _pragmaValue(SqlParser parser, {void Function(String)? onParsed}) {
    final parenthesized = parser.take('(');
    if (!parenthesized) parser.require('=');
    final negative = parser.take('-');
    final signed = negative || parser.take('+');
    final token = parser.current;
    if (![SqlTokenKind.identifier, SqlTokenKind.string, SqlTokenKind.number]
            .contains(token.kind) ||
        token.keyword == 'NULL' ||
        signed && token.kind != SqlTokenKind.number) {
      throw const SqlException('Invalid PRAGMA value');
    }
    parser.position++;
    if (parenthesized) parser.require(')');
    final value = negative ? '-${token.text}' : token.text;
    // SQLite applies connection-state PRAGMAs during preparation, even if
    // trailing SQL later fails. Header writes wait until preparation succeeds.
    onParsed?.call(value);
    parser.finish();
    return value;
  }

  int _pragmaInteger(String value) {
    final match =
        RegExp(r'^([+-]?)(0[xX][0-9a-fA-F]+|[0-9]+)').firstMatch(value);
    if (match == null) return 0;
    final digits = match[2]!;
    final hexadecimal = digits.startsWith('0x') || digits.startsWith('0X');
    final significant = (hexadecimal ? digits.substring(2) : digits)
        .replaceFirst(RegExp(r'^0+'), '');
    if (significant.isEmpty) return 0;
    if (significant.length > (hexadecimal ? 8 : 10)) return 0;
    var number = BigInt.parse(significant, radix: hexadecimal ? 16 : 10);
    if (hexadecimal && number > BigInt.from(2147483647)) return 0;
    if (match[1] == '-') number = -number;
    return number >= BigInt.from(-2147483648) &&
            number <= BigInt.from(2147483647)
        ? number.toInt()
        : 0;
  }

  bool _pragmaBoolean(String value) {
    if (value.isNotEmpty &&
        value.codeUnitAt(0) >= 48 &&
        value.codeUnitAt(0) <= 57) {
      return _pragmaInteger(value) != 0;
    }
    return ['on', 'yes', 'true'].contains(asciiLower(value));
  }

  Future<MutationResult> _transaction(SqlParser parser) async {
    final op = parser.current.keyword;
    parser.position++;
    if (op == 'BEGIN') {
      if (!parser.take('DEFERRED') && !parser.take('IMMEDIATE')) {
        parser.take('EXCLUSIVE');
      }
      parser.take('TRANSACTION');
      parser.finish();
      if (inTransaction) throw const SqlException('Transaction already active');
      _checkpoint = _snapshot();
      _explicitTransaction = true;
      try {
        _virtualTransaction('xBegin');
      } catch (error) {
        _clearTransaction();
        rethrow;
      }
    } else if (op == 'SAVEPOINT') {
      final name = asciiLower(parser.identifier());
      parser.finish();
      _checkpoint ??= _snapshot();
      _savepoints.add((name, _snapshot()));
    } else if (op == 'RELEASE') {
      parser.take('SAVEPOINT');
      final name = asciiLower(parser.identifier());
      parser.finish();
      final index = _savepoints.lastIndexWhere((entry) => entry.$1 == name);
      if (index < 0) throw const SqlException('No such savepoint');
      if (index == 0 && !_explicitTransaction) {
        await _commitTransaction();
      } else {
        _savepoints.removeRange(index, _savepoints.length);
      }
    } else if (op == 'ROLLBACK') {
      parser.take('TRANSACTION');
      if (parser.take('TO')) {
        parser.take('SAVEPOINT');
        final name = asciiLower(parser.identifier());
        parser.finish();
        final index = _savepoints.lastIndexWhere((entry) => entry.$1 == name);
        if (index < 0) throw const SqlException('No such savepoint');
        _restoreSnapshot(_savepoints[index].$2);
        _savepoints.removeRange(index + 1, _savepoints.length);
      } else {
        parser.finish();
        if (!inTransaction) throw const SqlException('No active transaction');
        _restoreSnapshot(_checkpoint!);
        _clearTransaction();
        _virtualTransaction('xRollback');
      }
    } else {
      parser.take('TRANSACTION');
      parser.finish();
      if (!inTransaction) throw const SqlException('No active transaction');
      await _commitTransaction();
    }
    return const MutationResult(0, null);
  }

  void _clearTransaction() {
    _checkpoint = null;
    _explicitTransaction = false;
    _savepoints.clear();
  }

  void _virtualTransaction(String action) {
    for (final module in functions.virtualTables.modules) {
      invokeVirtualTableCallback(action, () {
        switch (action) {
          case 'xBegin':
            module.xBegin();
          case 'xCommit':
            module.xCommit();
          case 'xRollback':
            module.xRollback();
        }
      });
    }
  }

  Future<void> _commitTransaction() async {
    if (_foreignKeys) {
      if (_liveMain != null) {
        _liveMain!.validateForeignKeys();
      } else {
        (await ImageMutations.load(_image)).validateForeignKeys();
      }
    }
    try {
      _virtualTransaction('xCommit');
    } catch (error) {
      _failed = true;
      _clearTransaction();
      rethrow;
    }
    if (_journal != null) {
      try {
        _materializeMain();
        await _journal.commitImage(_image);
      } catch (_) {
        _failed = true;
        rethrow;
      }
    }
    _clearTransaction();
  }

  /// Rolls back an open transaction and rejects later use.
  Future<void> close() async {
    if (_busy) throw StateError('Database operation in progress');
    if (_closed) return;
    if (inTransaction) {
      _restoreSnapshot(_checkpoint!);
      _clearTransaction();
    }
    if (!_failed) _materializeMain();
    final reader = _mainReader;
    _mainReader = null;
    _mainReaderImage = null;
    _closed = true;
    await _journal?.close();
    if (reader != null) await reader.close();
  }

  (String, String) _pragmaName(SqlParser parser) {
    var name = asciiLower(parser.identifier());
    var schema = 'main';
    if (parser.take('.')) {
      schema = name;
      if (!_schemaOrder().contains(schema)) {
        throw SqlException('Unknown database: $schema');
      }
      name = asciiLower(parser.identifier());
    }
    return (schema, name);
  }

  Future<QueryResult> _queryPragma(
      SqlParser parser, String sql, List<Object?> parameters) async {
    if (parameters.isNotEmpty) {
      throw const SqlException('PRAGMA bindings unsupported');
    }
    final parsed = _pragmaName(parser);
    final schema = parsed.$1;
    final name = parsed.$2;
    const connection = {
      'foreign_keys',
      'recursive_triggers',
      'cache_size',
      'busy_timeout',
      'synchronous',
      'journal_mode',
      'auto_vacuum',
      'database_list'
    };
    final argument = parser.current.text == '=' || parser.current.text == '(';
    final connectionWrite =
        argument && connection.contains(name) && name != 'database_list';
    if (connectionWrite) {
      final value = _pragmaValue(parser);
      _applyConnectionPragma(name, value, schema);
    } else if (!argument) {
      parser.finish();
    }
    if (name == 'database_list') return _databaseList();
    if (!connection.contains(name)) {
      return _readImage(schema, imageSql(sql, schema));
    }
    return QueryResult([
      name
    ], [
      [_connectionPragmaValue(name, schema)]
    ]);
  }

  Object? _connectionPragmaValue(String name, String schema) {
    switch (name) {
      case 'foreign_keys':
        return boolean(_foreignKeys);
      case 'recursive_triggers':
        return boolean(_recursiveTriggers);
      case 'cache_size':
        return BigInt.from(_cacheSize);
      case 'busy_timeout':
        return BigInt.from(_busyTimeout);
      case 'synchronous':
        return BigInt.from(_synchronous);
      case 'journal_mode':
        return sqlJournalMode(_imageFor(schema)[18]);
      case 'auto_vacuum':
        return BigInt.zero;
      default:
        throw SqlException('Unsupported PRAGMA $name');
    }
  }

  void _applyConnectionPragma(String name, String value, String schema) {
    switch (name) {
      case 'foreign_keys':
        if (!inTransaction) _foreignKeys = _pragmaBoolean(value);
      case 'recursive_triggers':
        _recursiveTriggers = _pragmaBoolean(value);
      case 'cache_size':
        final size = _pragmaInteger(value);
        if (size == 0) throw const SqlException('Invalid cache_size');
        _cacheSize = size;
      case 'busy_timeout':
        final timeout = _pragmaInteger(value);
        if (timeout < 0) throw const SqlException('Invalid busy_timeout');
        _busyTimeout = timeout;
      case 'synchronous':
        _synchronous = _synchronousMode(value);
      case 'journal_mode':
        final requested = asciiLower(value);
        final current = sqlJournalMode(_imageFor(schema)[18]);
        if (requested != current) {
          throw SqlException('journal_mode $requested is not implemented');
        }
      case 'auto_vacuum':
        throw const SqlException('auto_vacuum is not implemented');
      default:
        throw SqlException('Unsupported writable PRAGMA');
    }
  }

  int _synchronousMode(String value) {
    const named = {'off': 0, 'normal': 1, 'full': 2, 'extra': 3};
    final mapped = named[asciiLower(value)];
    if (mapped != null) return mapped;
    final number = _pragmaInteger(value);
    if (number < 0 || number > 3) {
      throw const SqlException('Invalid synchronous');
    }
    return number;
  }

  QueryResult _databaseList() {
    final rows = <List<Object?>>[
      [BigInt.zero, 'main', '']
    ];
    var sequence = 1;
    if (_tempUsed) {
      rows.add([BigInt.from(sequence++), 'temp', '']);
    }
    for (final name in _attached.keys) {
      rows.add([BigInt.from(sequence++), name, '']);
    }
    return QueryResult(['seq', 'name', 'file'], rows);
  }

  Future<void> _commitSchema(String schema, Uint8List image) async {
    if (schema == 'main' && _journal != null && !inTransaction) {
      try {
        await _journal.commitImage(image);
      } catch (_) {
        _failed = true;
        rethrow;
      }
    }
    _storeImage(schema, image);
  }

  Future<void> _attach(String name, String path) async {
    if (const {'main', 'temp'}.contains(name) || _attached.containsKey(name)) {
      throw SqlException('database $name is already in use');
    }
    if (_attached.isNotEmpty) {
      throw const SqlException('too many attached databases');
    }
    final Uint8List bytes;
    if (path == ':memory:') {
      bytes = DatabaseImageBuilder.empty();
    } else {
      final reader = attachFile;
      if (reader == null) {
        throw SqlException('unable to open database: $path');
      }
      bytes = Uint8List.fromList(await reader(path));
      if (bytes.length > 64 * 1024 * 1024) {
        throw const SqlException('attached database exceeds 64 MiB');
      }
    }
    final storage = MemoryStorageBackend();
    await storage.write(0, bytes);
    final opened = await SqliteDatabase.openReadOnly(storage);
    await opened.close();
    _attached[name] = Uint8List.fromList(bytes);
    _invalidateCatalog();
  }

  void _detach(String name) {
    if (!_attached.containsKey(name)) {
      throw SqlException('no such database: $name');
    }
    _attached.remove(name);
    _invalidateCatalog();
  }

  Future<QueryResult> _crossQuery(
      StatementRoute route, List<Object?> parameters) async {
    _materializeMain();
    final counts = <String, int>{};
    for (final use in route.uses) {
      final key = asciiLower(use.table);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final rename = <String, String>{};
    final scratch = await MutableSqliteDatabase.create();
    try {
      final seen = <String>{};
      for (final use in route.uses) {
        final key = '${use.schema}.${asciiLower(use.table)}';
        if (!seen.add(key)) continue;
        final collision = (counts[asciiLower(use.table)] ?? 0) > 1;
        final name = collision ? '${use.schema}__${use.table}' : use.table;
        rename[key] = name;
        final quotedTable = '"${use.table.replaceAll('"', '""')}"';
        final rows = await _readImage(use.schema, 'SELECT * FROM $quotedTable');
        final columns = [
          for (var i = 0; i < rows.columns.length; i++)
            '"${rows.columns[i].replaceAll('"', '""')}" ${rows.columnDeclaredTypes[i]}'
                .trim()
        ];
        final quoted = '"${name.replaceAll('"', '""')}"';
        await scratch.execute('CREATE TABLE $quoted(${columns.join(',')})');
        for (final row in rows.rows) {
          final marks = List.filled(row.length, '?').join(',');
          await scratch.execute('INSERT INTO $quoted VALUES($marks)', row);
        }
      }
      return await scratch.query(
          rewriteSchemaTables(route.sql, rename), parameters);
    } finally {
      await scratch.close();
    }
  }
}
