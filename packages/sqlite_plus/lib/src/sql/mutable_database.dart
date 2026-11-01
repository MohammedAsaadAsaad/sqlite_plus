import 'dart:async';
import 'dart:typed_data';

import '../btree/database_image_builder.dart';
import '../btree/incremental_vacuum.dart';
import '../format/database_header.dart';
import 'image_mutations.dart';
import '../pager/image_pager.dart';
import '../pager/rollback_journal_pager.dart';
import '../pager/schema_commit.dart';
import '../storage/durable_storage_backend.dart';
import '../storage/memory_storage_backend.dart';
import 'catalog.dart';
import 'database.dart';
import 'explain_bytecode.dart';
import 'parser.dart';
import 'schema_router.dart';
import 'tokenizer.dart';
import 'vacuum_into.dart';
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

/// Opens an empty in-memory database.
///
/// This is [MutableSqliteDatabase.create]. [pageSize] is a power of two from
/// 512 to 65536. [encoding] is 1 for UTF-8, 2 for UTF-16le, or 3 for UTF-16be.
Future<MutableSqliteDatabase> openInMemory({
  int pageSize = 4096,
  int encoding = 1,
}) =>
    MutableSqliteDatabase.create(pageSize: pageSize, encoding: encoding);

/// Serialized image mutations with constraints, secondary indexes and row triggers.
/// In-memory by default; an ImagePager supplies the durable commit boundary.
/// Transactions and savepoints retain independent image snapshots.
final class MutableSqliteDatabase {
  MutableSqliteDatabase._(this._image, this._journal) {
    _flexibleAutoVacuum.add('temp');
  }
  Uint8List _image;
  Uint8List _temp = DatabaseImageBuilder.empty();
  final Map<String, Uint8List> _attached = {};
  final Map<String, ImagePager> _attachedPagers = {};
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

  /// Connection journal mode. Absent means the default: `memory` for an
  /// in-memory main database, otherwise `delete` (or `wal` when byte 18 is 2).
  final Map<String, String> _journalModes = {};

  /// Schemas whose first page image has not been stored. A fresh connection
  /// can still turn auto-vacuum on. An opened file cannot.
  final Set<String> _flexibleAutoVacuum = {};

  /// Reads ATTACH file paths. Memory ATTACH does not use it. A missing reader
  /// rejects file paths. The bytes are a connection-local copy when
  /// [openAttachedPager] is null.
  Future<Uint8List> Function(String path)? attachFile;

  /// Opens the durable store for `ATTACH 'path'`. When set, a file path uses
  /// this instead of [attachFile]. The connection closes the pager.
  Future<ImagePager> Function(String path)? openAttachedPager;

  /// Commit record for a transaction that changes two rollback journals.
  /// The caller owns the backend. A memory attachment does not use it.
  DurableStorageBackend? schemaCommitJournal;

  /// When true, `VACUUM INTO` flushes its temporary file and stops before
  /// renaming it onto the destination.
  bool crashVacuumIntoBeforeRename = false;

  /// Scalar, aggregate, and collation callbacks for this connection.
  final functions = SqlFunctionRegistry();

  /// Unresolved double-quoted expression identifiers become strings when this
  /// is true. The default is false.
  bool get doubleQuotedStrings => functions.doubleQuotedStrings;
  set doubleQuotedStrings(bool value) => functions.doubleQuotedStrings = value;
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
  ///
  /// Auto-vacuum can still be turned on, as on a fresh SQLite connection,
  /// until the first page image is stored.
  static Future<MutableSqliteDatabase> create(
      {int pageSize = 4096, int encoding = 1}) async {
    final database = await fromImage(
        DatabaseImageBuilder.empty(pageSize: pageSize, encoding: encoding));
    database._flexibleAutoVacuum.add('main');
    return database;
  }

  /// Reopens a database from [exportImage] bytes.
  static Future<MutableSqliteDatabase> fromImage(Uint8List image) async {
    if (image.length >= 100) {
      final header = DatabaseHeader.decode(image);
      if (header.writeVersion != 1 ||
          header.readVersion != 1 ||
          header.largestRootPage > header.databaseSize) {
        throw UnsupportedError(
            'Writer requires a complete rollback-format database image');
      }
      if (header.largestRootPage != 0) {
        try {
          await ImageMutations.load(Uint8List.fromList(image));
        } on UnsupportedError {
          rethrow;
        } catch (_) {
          throw UnsupportedError(
              'Writer requires a complete rollback-format database image');
        }
      }
    }
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
    _flexibleAutoVacuum.remove(schema);
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
      [List<Object?> parameters = const [],
      bool schemaView = false,
      bool browse = false]) async {
    if (schema == 'main' &&
        _dirtyMain &&
        (!schemaView || (_liveMain?.schemaChanged ?? false))) {
      _materializeMain();
    }
    if (schema == 'main') {
      final reader = await _cachedMainReader();
      return browse
          ? reader.browse(sql, parameters)
          : reader.query(sql, parameters);
    }
    final reader = await SqliteDatabase.openReadOnly(
        ByteImageStorage(_imageFor(schema)),
        functions: functions);
    try {
      return browse
          ? await reader.browse(sql, parameters)
          : await reader.query(sql, parameters);
    } finally {
      await reader.close();
    }
  }

  /// Runs one SQL statement and returns its rows.
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    if (_startsWithRowWrite(sql)) return _queryWrite(sql, parameters);
    return _exclusive(() => _queryUnlocked(sql, parameters));
  }

  Future<QueryResult> _queryWrite(String sql, List<Object?> parameters) async {
    final result = await execute(sql, parameters);
    return result.returning ?? QueryResult(const [], const []);
  }

  Future<QueryResult?> _explainBytecode(String sql) async {
    final direct = compileLiteralExplain(sql);
    if (direct != null) return direct;
    if (_dirtyMain) _materializeMain();
    final reader = await SqliteDatabase.openReadOnly(ByteImageStorage(_image));
    try {
      final header = DatabaseHeader.decode(_image);
      final catalog = reader.catalog;
      final schema = ExplainSchema(
        cookie: header.schemaCookie,
        table: (name) {
          final CatalogTable table;
          try {
            table = catalog.table(name);
          } on SqlException {
            return null;
          }
          if (table.virtual || table.rootPage <= 0) return null;
          return ExplainTable(
            table.name,
            table.rootPage,
            [for (final column in table.columns) column.name],
            rowidAlias: table.rowidAlias,
            withoutRowid: table.withoutRowid,
            generated: table.columns
                .any((column) => column.generatedExpression != null),
            affinity: table.columns
                .any((column) => column.declaredType.trim().isNotEmpty),
            indexed: table.autoIndexKeys.isNotEmpty ||
                table.uniqueKeys.isNotEmpty ||
                table.rowidAlias != null,
            notNull:
                table.columns.any((column) => column.notNull || column.hidden),
            defaults: [
              for (final column in table.columns)
                column.defaultSql != null ||
                    column.defaultExpression != null ||
                    column.defaultValue != null
            ],
          );
        },
      );
      return compileLiteralExplain(sql, schema: schema);
    } finally {
      await reader.close();
    }
  }

  Future<QueryResult> _queryUnlocked(String sql,
      [List<Object?> parameters = const []]) async {
    final live = _liveMain;
    if (live != null) {
      final fast = live.tryFastRead(sql, parameters);
      if (fast != null) return fast;
    }
    final explain = SqlParser(sql);
    if (explain.take('EXPLAIN')) {
      if (!(explain.take('QUERY') && explain.take('PLAN'))) {
        if (parameters.isNotEmpty) {
          throw const SqlException('EXPLAIN bytecode bindings unsupported');
        }
        final compiled =
            await _explainBytecode(sql.substring(explain.current.offset));
        if (compiled == null) {
          throw const SqlException('EXPLAIN bytecode is not implemented');
        }
        return compiled;
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
        return _planResult(reader.explainQueryPlan(route.sql));
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
        throw const SqlException('cross-database query could not be assembled');
      }
      return runZoned(() => _crossQuery(route, parameters),
          zoneValues: {_crossQueryKey: true});
    }
    const schemaTables = {
      'sqlite_schema',
      'sqlite_master',
      'sqlite_temp_schema'
    };
    final schemaView =
        route.uses.every((use) => schemaTables.contains(asciiLower(use.table)));
    return _readImage(route.schema!, route.sql, parameters, schemaView);
  }

  /// A window of a single-table read. [query] is unchanged.
  Future<QueryResult> browse(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final explain = SqlParser(sql);
        if (explain.take('EXPLAIN')) {
          if (!(explain.take('QUERY') && explain.take('PLAN'))) {
            if (parameters.isNotEmpty) {
              throw const SqlException('EXPLAIN bytecode bindings unsupported');
            }
            final compiled =
                await _explainBytecode(sql.substring(explain.current.offset));
            if (compiled == null) {
              throw const SqlException('EXPLAIN bytecode is not implemented');
            }
            return compiled;
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
            return _planResult(reader.explainQueryPlan(route.sql));
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
        return _readImage(
            route.schema!, route.sql, parameters, schemaView, true);
      });

  /// Runs one write statement inside the connection lock.
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    // Incremental auto-vacuum has to publish the previous statement first.
    // The freelist is the pages that statement grew and this one no longer uses.
    if (_dirtyMain &&
        _image.length >= 100 &&
        DatabaseHeader.decode(_image).autoVacuumMode == 2) {
      _materializeMain();
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
              final logical = journal is RollbackJournalPager
                  ? state.fileAddendCommit()
                  : null;
              if (logical != null) {
                // The redo sync is the commit. Leaves stay cached, and the
                // live rows keep the addend until a later read materializes it.
                try {
                  await (journal as RollbackJournalPager)
                      .commitAddend(logical.root, logical.deltas);
                } catch (_) {
                  _failed = true;
                  rethrow;
                }
                state.noteAddendJournaled();
              } else {
                final image = state.durableImage();
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
          'auto_vacuum',
          'incremental_vacuum'
        };
        if (!writable.contains(name)) {
          throw const SqlException('Unsupported writable PRAGMA');
        }
        if (name == 'incremental_vacuum') {
          final value = parser.current.text == '=' || parser.current.text == '('
              ? _pragmaValue(parser)
              : null;
          if (value == null) parser.finish();
          await _applyIncrementalVacuum(parsed.$1, value);
          return const MutationResult(0, null);
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
        } else if (name == 'auto_vacuum') {
          await _applyAutoVacuum(parsed.$1, value);
        } else if (name == 'journal_mode') {
          await _setJournalMode(parsed.$1, value);
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
      final names = await _schemaCatalog();
      final route = routeMutation(sql, names);
      if (route.kind == 'attach') {
        await _attach(route.name!, route.argument!);
        return const MutationResult(0, null);
      }
      if (route.kind == 'detach') {
        await _detach(route.name!);
        return const MutationResult(0, null);
      }
      final schema = route.schema!;
      var statementSql = route.sql;
      var statementParameters = parameters;
      if (route.kind == 'cross-insert') {
        final rewritten = await _prepareCrossInsert(schema, sql, parameters);
        if (rewritten == null) return const MutationResult(0, null);
        statementSql = rewritten.sql;
        statementParameters = rewritten.parameters;
      }
      final keyword = SqlParser(statementSql).current.keyword;
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
      final previousTarget = state.reportedTarget;
      state.reportedTarget = qualifiedDmlTarget(sql);
      try {
        result = route.kind == 'cross-write'
            ? await _runCrossWrite(state, sql, schema, parameters, names,
                foreignKeys: _foreignKeys, inTransaction: inTransaction)
            : await state.execute(statementSql, statementParameters,
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
      } finally {
        state.reportedTarget = previousTarget;
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
      final copy = result.vacuumInto;
      if (copy != null) {
        await publishVacuumInto(copy.path, copy.bytes,
            crashBeforeRename: crashVacuumIntoBeforeRename);
      }
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
    if (_attachedPagers.isEmpty) {
      if (_journal != null) {
        try {
          _materializeMain();
          await _journal.commitImage(_image);
        } catch (_) {
          _failed = true;
          rethrow;
        }
      }
    } else {
      await _commitFileSchemas();
    }
    _clearTransaction();
  }

  Future<void> _commitFileSchemas() async {
    _materializeMain();
    final dirty =
        <({String name, RollbackJournalPager pager, Uint8List image})>[];
    void consider(
        String name, ImagePager? pager, Uint8List image, Uint8List? original) {
      if (pager is! RollbackJournalPager) return;
      if (original != null && _sameImage(image, original)) return;
      dirty.add((name: name, pager: pager, image: image));
    }

    if (_journal is RollbackJournalPager) {
      consider('main', _journal, _image, _checkpoint!.main);
    }
    for (final name in _attachedPagers.keys) {
      consider(name, _attachedPagers[name], _attached[name]!,
          _checkpoint!.attached[name]);
    }
    final mainDirty = _journal != null &&
        _journal is! RollbackJournalPager &&
        !_sameImage(_image, _checkpoint!.main);
    if (mainDirty && dirty.isNotEmpty) {
      throw const SqlException(
          'durable commit across databases requires rollback journals');
    }
    if (dirty.length >= 2) {
      final journal = schemaCommitJournal;
      if (journal == null) {
        throw const SqlException(
            'durable commit across databases requires a schema commit journal');
      }
      try {
        await SchemaCommit.commit(journal: journal, schemas: dirty);
      } catch (_) {
        _failed = true;
        rethrow;
      }
      return;
    }
    if (_journal != null) {
      try {
        await _journal.commitImage(_image);
      } catch (_) {
        _failed = true;
        rethrow;
      }
    }
    for (final schema in dirty) {
      if (schema.name == 'main') continue;
      try {
        await schema.pager.commitImage(schema.image);
      } catch (_) {
        _failed = true;
        rethrow;
      }
    }
  }

  bool _sameImage(Uint8List left, Uint8List right) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
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
    try {
      await _journal?.close();
    } finally {
      for (final pager in _attachedPagers.values) {
        await pager.close();
      }
      _attachedPagers.clear();
    }
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
      'incremental_vacuum',
      'database_list'
    };
    final argument = parser.current.text == '=' || parser.current.text == '(';
    final connectionWrite =
        argument && connection.contains(name) && name != 'database_list';
    if (name == 'incremental_vacuum') {
      final value = argument ? _pragmaValue(parser) : null;
      if (!argument) parser.finish();
      await _applyIncrementalVacuum(schema, value);
      return QueryResult([name], const []);
    }
    if (name == 'auto_vacuum' && argument) {
      final value = _pragmaValue(parser);
      parser.finish();
      await _applyAutoVacuum(schema, value);
      return QueryResult([name], const []);
    }
    if (connectionWrite) {
      final value = _pragmaValue(parser);
      if (name == 'journal_mode') {
        await _setJournalMode(schema, value);
      } else {
        _applyConnectionPragma(name, value, schema);
      }
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
        return _journalModeFor(schema);
      case 'auto_vacuum':
        final image = _imageFor(schema);
        if (image.length < 100) return BigInt.zero;
        return BigInt.from(DatabaseHeader.decode(image).autoVacuumMode);
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
      default:
        throw SqlException('Unsupported writable PRAGMA');
    }
  }

  String _journalModeFor(String schema) {
    final stored = _journalModes[schema];
    if (stored != null) return stored;
    if (schema == 'main' && _journal == null) return 'memory';
    final image = _imageFor(schema);
    if (schema == 'main' && image.length > 18 && image[18] == 2) return 'wal';
    return 'delete';
  }

  /// In-memory main stays `memory`. A file keeps `delete` for `off` and for an
  /// unknown name. `memory` changes only this connection. `wal` rewrites header
  /// bytes 18 and 19 and checkpoints. `persist` and `truncate` apply on the
  /// next file commit.
  Future<void> _setJournalMode(String schema, String value) async {
    final requested = asciiLower(value);
    if (schema == 'main' && _journal == null) {
      _journalModes[schema] = 'memory';
      return;
    }
    const known = {'delete', 'persist', 'off', 'truncate', 'memory', 'wal'};
    if (!known.contains(requested) || requested == 'off') return;
    if (requested == 'wal' && schema != 'main') return;
    final current = _journalModeFor(schema);
    if (requested != current &&
        (requested == 'wal' || current == 'wal') &&
        inTransaction) {
      throw SqlException(
          'cannot change ${requested == 'wal' ? 'into' : 'out of'} wal mode from within a transaction');
    }
    if (requested == 'wal' && current != 'wal') {
      await _writeJournalVersion(schema, 2);
    } else if (current == 'wal' && requested != 'wal') {
      await _writeJournalVersion(schema, 1);
    }
    _journalModes[schema] = requested;
    final pager = _rollbackPager(schema);
    if (pager == null) return;
    final fileMode =
        requested == 'persist' || requested == 'truncate' || requested == 'wal'
            ? requested
            : 'delete';
    if (pager.fileJournalMode != fileMode) {
      await pager.setFileJournalMode(fileMode);
    }
  }

  RollbackJournalPager? _rollbackPager(String schema) {
    final pager = schema == 'main' ? _journal : _attachedPagers[schema];
    return pager is RollbackJournalPager ? pager : null;
  }

  /// Header bytes 18 and 19 and the change counter follow the pinned WAL switch.
  Future<void> _writeJournalVersion(String schema, int version) async {
    if (schema == 'main') _materializeMain();
    final image = Uint8List.fromList(_imageFor(schema));
    if (image.length < 100 || image[18] == version && image[19] == version) {
      return;
    }
    image[18] = version;
    image[19] = version;
    final fields = ByteData.sublistView(image);
    final counter = (fields.getUint32(24) + 1) & 0xffffffff;
    fields.setUint32(24, counter);
    fields.setUint32(92, counter);
    final pager = _rollbackPager(schema);
    if (pager != null) {
      await pager.setFileJournalMode(version == 2 ? 'wal' : 'delete');
      await _commitSchema(schema, image);
      if (version == 1) await pager.setFileJournalMode('delete');
      return;
    }
    await _commitSchema(schema, image);
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

  QueryResult _planResult(List<ExplainPlanRow> rows) => QueryResult(const [
        'id',
        'parent',
        'notused',
        'detail'
      ], [
        for (final row in rows)
          [
            BigInt.from(row.id),
            BigInt.from(row.parent),
            BigInt.from(row.notused),
            row.detail
          ]
      ]);

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
    if (!inTransaction) {
      final pager = schema == 'main' ? _journal : _attachedPagers[schema];
      if (pager != null) {
        try {
          await pager.commitImage(image);
        } catch (_) {
          _failed = true;
          rethrow;
        }
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
    if (path != ':memory:' && openAttachedPager != null) {
      final pager = await openAttachedPager!(path);
      try {
        final bytes = Uint8List.fromList(await pager.readImage());
        if (bytes.length > 64 * 1024 * 1024) {
          throw const SqlException('attached database exceeds 64 MiB');
        }
        final storage = MemoryStorageBackend();
        await storage.write(0, bytes);
        final opened = await SqliteDatabase.openReadOnly(storage);
        await opened.close();
        _attachedPagers[name] = pager;
        _attached[name] = bytes;
      } catch (_) {
        await pager.close();
        rethrow;
      }
      _invalidateCatalog();
      return;
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
    if (path == ':memory:') _flexibleAutoVacuum.add(name);
    _invalidateCatalog();
  }

  /// `PRAGMA incremental_vacuum` removes freelist pages from an incremental
  /// database. No argument, `0`, and a negative count clear the whole freelist.
  /// Any other database mode keeps its bytes.
  Future<void> _applyIncrementalVacuum(String schema, String? value) async {
    if (schema == 'main') _materializeMain();
    final image = _imageFor(schema);
    if (image.length < 100) return;
    final header = DatabaseHeader.decode(image);
    if (header.autoVacuumMode != 2 || header.freelistPages == 0) return;
    final requested = value == null ? 0 : _pragmaInteger(value);
    final next = IncrementalVacuum.apply(image, requested);
    if (next.length == image.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != image[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    await _commitSchema(schema, next);
  }

  /// `none`/`full`/`incremental`, or an integer kept only when it is 0, 1, or 2.
  int _parseAutoVacuum(String value) {
    switch (asciiLower(value)) {
      case 'none':
        return 0;
      case 'full':
        return 1;
      case 'incremental':
        return 2;
    }
    final number = _pragmaInteger(value);
    if (number >= 0 && number <= 2) return number;
    return 0;
  }

  /// Writes the auto-vacuum cookies when this connection is still flexible, or
  /// switches full and incremental after the database is already auto-vacuum.
  /// Turning auto-vacuum on or off is ignored once the page image is fixed.
  /// The assignment itself returns no row.
  Future<void> _applyAutoVacuum(String schema, String value) async {
    final requested = _parseAutoVacuum(value);
    if (schema == 'main') _materializeMain();
    final image = Uint8List.fromList(_imageFor(schema));
    if (image.length < 100) return;
    final header = DatabaseHeader.decode(image);
    final current = header.autoVacuumMode;
    final flexible = _flexibleAutoVacuum.contains(schema);
    if (flexible) {
      if (requested == 0) return;
    } else if (current == 0 || requested == 0) {
      return;
    }
    final fields = ByteData.sublistView(image);
    final oldLargest = fields.getUint32(52);
    final oldIncremental = fields.getUint32(64);
    if (oldLargest == 0) fields.setUint32(52, 1);
    fields.setUint32(64, requested == 2 ? 1 : 0);
    if (fields.getUint32(52) == oldLargest &&
        fields.getUint32(64) == oldIncremental) {
      return;
    }
    final counter = (fields.getUint32(24) + 1) & 0xffffffff;
    fields.setUint32(24, counter);
    fields.setUint32(92, counter);
    await _commitSchema(schema, image);
  }

  Future<void> _detach(String name) async {
    if (!_attached.containsKey(name)) {
      throw SqlException('no such database: $name');
    }
    if (inTransaction) {
      final original = _checkpoint!.attached[name];
      final current = _attached[name];
      if (original == null ||
          current == null ||
          !_sameImage(current, original)) {
        throw SqlException('database $name is locked');
      }
    }
    final pager = _attachedPagers.remove(name);
    _attached.remove(name);
    _flexibleAutoVacuum.remove(name);
    _journalModes.remove(name);
    if (inTransaction) {
      // DETACH is durable for the connection. Rollback does not reattach it.
      _checkpoint = _withoutAttachment(_checkpoint!, name);
      for (var i = 0; i < _savepoints.length; i++) {
        final entry = _savepoints[i];
        _savepoints[i] = (entry.$1, _withoutAttachment(entry.$2, name));
      }
    }
    _invalidateCatalog();
    if (pager != null) await pager.close();
  }

  _ConnectionSnapshot _withoutAttachment(
      _ConnectionSnapshot snapshot, String name) {
    return _ConnectionSnapshot(
        snapshot.main,
        snapshot.temp,
        {
          for (final entry in snapshot.attached.entries)
            if (entry.key != name) entry.key: entry.value
        },
        snapshot.logical);
  }

  /// Copies foreign tables into [state], runs the write, then drops the copies.
  /// `changes()` stays the write's own count.
  Future<MutationImage> _runCrossWrite(ImageMutations state, String sql,
      String schema, List<Object?> parameters, SchemaNames names,
      {required bool foreignKeys, required bool inTransaction}) async {
    final plan = planCrossWrite(sql, names, schema);
    if (plan.copies.isEmpty) {
      return state.execute(stripSchema(sql, schema), parameters,
          foreignKeys: foreignKeys, inTransaction: inTransaction);
    }
    final counters = SqlFunctionRegistry.current?.connectionState;
    final savedTotal = counters?.totalChanges ?? BigInt.zero;
    final savedLast = counters?.lastInsertRowid ?? BigInt.zero;
    for (final copy in plan.copies) {
      await _installCrossCopy(state, copy);
    }
    final updated = await state.execute(plan.sql, parameters,
        foreignKeys: foreignKeys, inTransaction: inTransaction);
    var image = updated.image;
    for (final copy in plan.copies.reversed) {
      final dropped = await state.execute(
          'DROP TABLE ${_sqlQuote(copy.helper)}', const [],
          foreignKeys: foreignKeys, inTransaction: inTransaction);
      image = dropped.image;
    }
    if (counters != null) {
      counters.changes = BigInt.from(updated.changes);
      counters.totalChanges = savedTotal + BigInt.from(updated.changes);
      final inserted = updated.changes > 0 &&
          updated.lastRowid != null &&
          statementInsertsRows(sql);
      counters.lastInsertRowid = inserted ? updated.lastRowid! : savedLast;
    }
    return MutationImage(
        image, updated.changes, updated.lastRowid, updated.returning);
  }

  Future<void> _installCrossCopy(ImageMutations state, CrossCopy copy) async {
    final quoted = _sqlQuote(copy.table);
    final info = await _readImage(copy.schema, 'PRAGMA table_info($quoted)');
    final definitions = <String>[];
    var primaryKeys = 0;
    var integerKey = false;
    for (final row in info.rows) {
      final name = row[1].toString();
      final type = row[2]?.toString() ?? '';
      final key = row[5];
      final primary =
          key is BigInt ? key != BigInt.zero : key is int && key != 0;
      if (primary) {
        primaryKeys++;
        if (type.toUpperCase() == 'INTEGER') integerKey = true;
      }
      definitions.add('${_sqlQuote(name)} $type'.trim());
    }
    await state.execute(
        'CREATE TABLE ${_sqlQuote(copy.helper)}(${definitions.join(',')})',
        const []);
    final alias = integerKey && primaryKeys == 1;
    QueryResult data;
    var withRowid = false;
    if (!alias) {
      try {
        data = await _readImage(copy.schema, 'SELECT rowid, * FROM $quoted');
        withRowid = data.columns.isNotEmpty &&
            asciiLower(data.columns.first) == 'rowid';
      } on SqlException {
        data = await _readImage(copy.schema, 'SELECT * FROM $quoted');
      }
    } else {
      data = await _readImage(copy.schema, 'SELECT * FROM $quoted');
    }
    if (data.rows.isEmpty) return;
    final columnSql =
        (withRowid ? data.columns.skip(1) : data.columns).map(_sqlQuote);
    final marks = List.filled(data.columns.length, '?').join(',');
    final into = withRowid
        ? 'INSERT INTO ${_sqlQuote(copy.helper)}(rowid, ${columnSql.join(',')}) VALUES($marks)'
        : 'INSERT INTO ${_sqlQuote(copy.helper)} VALUES($marks)';
    for (final row in data.rows) {
      await state.execute(into, row);
    }
  }

  /// Reads the other schemas, then returns an insert the target image can run.
  /// An empty source writes nothing.
  Future<({String sql, List<Object?> parameters})?> _prepareCrossInsert(
      String schema, String sql, List<Object?> parameters) async {
    final parts = insertSelectParts(sql);
    if (parts == null) {
      throw const SqlException('cross-database statement is not supported');
    }
    final select = SqlParser(parts.selectSql).select();
    final count = select.parameterCount;
    final selected = await _queryUnlocked(parts.selectSql,
        parameters.length < count ? parameters : parameters.sublist(0, count));
    if (selected.rows.isEmpty) return null;
    final width = selected.rows.first.length;
    final tuple = '(${List.filled(width, '?').join(',')})';
    final values =
        'VALUES ${List.filled(selected.rows.length, tuple).join(',')}';
    final head = stripSchema(parts.head, schema);
    final tail = stripSchema(parts.tail, schema);
    final prefix = _endsWithSpace(head) ? head : '$head ';
    final suffix = tail.isEmpty || _startsWithSpace(tail) ? tail : ' $tail';
    return (
      sql: '$prefix$values$suffix',
      parameters: [
        for (final row in selected.rows) ...row,
        ...parameters.skip(count),
      ],
    );
  }

  String _sqlQuote(String name) => '"${name.replaceAll('"', '""')}"';

  bool _endsWithSpace(String text) {
    if (text.isEmpty) return false;
    final unit = text.codeUnitAt(text.length - 1);
    return unit == 9 || unit == 10 || unit == 13 || unit == 32;
  }

  bool _startsWithSpace(String text) {
    if (text.isEmpty) return false;
    final unit = text.codeUnitAt(0);
    return unit == 9 || unit == 10 || unit == 13 || unit == 32;
  }

  bool _startsWithRowWrite(String sql) {
    final keyword = _leadingKeyword(sql);
    if (keyword == null) return false;
    if (keyword == 'INSERT' ||
        keyword == 'REPLACE' ||
        keyword == 'UPDATE' ||
        keyword == 'DELETE') {
      return true;
    }
    if (keyword != 'WITH') return false;
    final tokens = SqlTokenizer.tokenize(sql);
    var depth = 0;
    for (final token in tokens) {
      if (token.text == '(') {
        depth++;
      } else if (token.text == ')') {
        depth--;
      } else if (depth == 0 &&
          (token.keyword == 'INSERT' ||
              token.keyword == 'REPLACE' ||
              token.keyword == 'UPDATE' ||
              token.keyword == 'DELETE')) {
        return true;
      }
    }
    return false;
  }

  String? _leadingKeyword(String sql) {
    var index = 0;
    final length = sql.length;
    while (index < length) {
      while (index < length) {
        final unit = sql.codeUnitAt(index);
        if (unit == 9 || unit == 10 || unit == 12 || unit == 13 || unit == 32) {
          index++;
          continue;
        }
        break;
      }
      if (index + 1 < length &&
          sql.codeUnitAt(index) == 45 &&
          sql.codeUnitAt(index + 1) == 45) {
        index += 2;
        while (index < length && sql.codeUnitAt(index) != 10) {
          index++;
        }
        continue;
      }
      if (index + 1 < length &&
          sql.codeUnitAt(index) == 47 &&
          sql.codeUnitAt(index + 1) == 42) {
        final end = sql.indexOf('*/', index + 2);
        if (end < 0) return null;
        index = end + 2;
        continue;
      }
      break;
    }
    if (index >= length) return null;
    final start = index;
    var unit = sql.codeUnitAt(index);
    var upper = unit >= 97 && unit <= 122 ? unit - 32 : unit;
    if (upper < 65 || upper > 90) return null;
    index++;
    while (index < length) {
      unit = sql.codeUnitAt(index);
      upper = unit >= 97 && unit <= 122 ? unit - 32 : unit;
      final letter = upper >= 65 && upper <= 90;
      final digit = unit >= 48 && unit <= 57;
      if (!(letter || digit || unit == 95)) break;
      index++;
    }
    return sql.substring(start, index).toUpperCase();
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
