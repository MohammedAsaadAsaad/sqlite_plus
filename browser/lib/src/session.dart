import 'package:flutter/foundation.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

import 'format.dart';

/// One object from `sqlite_schema`.
class SchemaObject {
  const SchemaObject({
    required this.type,
    required this.name,
    required this.table,
    required this.sql,
  });

  final String type;
  final String name;
  final String table;
  final String? sql;
}

/// A column from `PRAGMA table_info`.
class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.type,
    required this.notNull,
    required this.primaryKey,
  });

  final String name;
  final String type;
  final bool notNull;
  final bool primaryKey;
}

/// One page of a table.
class TableSlice {
  const TableSlice({
    required this.columns,
    required this.rows,
    required this.hasRowid,
    required this.total,
    required this.offset,
    required this.limit,
  });

  final List<ColumnInfo> columns;
  final List<List<Object?>> rows;
  final bool hasRowid;
  final int total;
  final int offset;
  final int limit;

  static const empty = TableSlice(
    columns: [],
    rows: [],
    hasRowid: false,
    total: 0,
    offset: 0,
    limit: 50,
  );
}

/// Rows from a read, or a change count from a write.
class StatementResult {
  const StatementResult.query(this.columns, this.rows)
      : changes = null,
        lastInsertRowid = null;

  const StatementResult.write(this.changes, this.lastInsertRowid)
      : columns = const [],
        rows = const [];

  final List<String> columns;
  final List<List<Object?>> rows;
  final int? changes;
  final BigInt? lastInsertRowid;

  bool get isQuery => changes == null;
}

/// An open sqlite_plus image: schema, pages, SQL, and cell edits.
class BrowserSession extends ChangeNotifier {
  MutableSqliteDatabase? _database;
  Future<void> _tail = Future<void>.value();

  /// File name or `Memory`.
  String label = 'Memory';

  /// A write happened since the last open or save.
  bool dirty = false;

  /// Schema objects, excluding `sqlite_%` names.
  List<SchemaObject> objects = const [];

  /// Opens an empty database.
  Future<void> openEmpty() {
    return _enqueue(() async {
      final next = await MutableSqliteDatabase.create();
      await _adopt(next, 'Memory');
    });
  }

  /// Replaces the image with [bytes].
  Future<void> openBytes(Uint8List bytes, {required String label}) {
    return _enqueue(() async {
      final next = await MutableSqliteDatabase.fromImage(bytes);
      await _adopt(next, label);
    });
  }

  /// Bytes a file can store.
  Uint8List exportBytes() {
    final database = _database;
    if (database == null) throw StateError('No database is open');
    return database.exportImage();
  }

  /// Clears [dirty] after the bytes are stored.
  void markSaved(String label) {
    this.label = label;
    dirty = false;
    notifyListeners();
  }

  /// Runs one statement.
  Future<StatementResult> run(String sql) {
    final text = sql.trim();
    if (text.isEmpty) {
      throw const SqlException('SQL is empty');
    }
    return _enqueue(() async {
      final database = _required();
      final result = await _run(database, text);
      if (!result.isQuery) {
        dirty = true;
        await _loadSchema(database);
      }
      notifyListeners();
      return result;
    });
  }

  /// Creates two books so the grid has something to show.
  Future<void> insertSample() {
    return _enqueue(() async {
      final database = _required();
      await database.execute(
        'CREATE TABLE IF NOT EXISTS books ('
        'id INTEGER PRIMARY KEY, title TEXT NOT NULL, pages INTEGER)',
      );
      await database.execute(
        'INSERT INTO books(title, pages) VALUES (?, ?), (?, ?)',
        ['Kept Garden', 320, 'Other Atlas', 40],
      );
      dirty = true;
      await _loadSchema(database);
      notifyListeners();
    });
  }

  /// One page of [table]. The first value of each row is the rowid when present.
  Future<TableSlice> slice(
    String table, {
    int offset = 0,
    int limit = 50,
  }) {
    return _enqueue(() async {
      final database = _required();
      final columns = await _columns(database, table);
      final counted = await database.query(
        'SELECT count(*) FROM ${quoteIdent(table)}',
      );
      final total = _asInt(counted.rows.single.single);
      final quoted = quoteIdent(table);
      QueryResult page;
      var hasRowid = true;
      try {
        page = await database.query(
          'SELECT rowid AS _browser_rowid, * FROM $quoted LIMIT ? OFFSET ?',
          [limit, offset],
        );
      } on SqlException {
        hasRowid = false;
        page = await database.query(
          'SELECT * FROM $quoted LIMIT ? OFFSET ?',
          [limit, offset],
        );
      }
      return TableSlice(
        columns: columns,
        rows: page.rows,
        hasRowid: hasRowid,
        total: total,
        offset: offset,
        limit: limit,
      );
    });
  }

  /// Writes one cell located by rowid.
  Future<void> updateCell(
    String table,
    BigInt rowid,
    String column,
    Object? value,
  ) {
    return _enqueue(() async {
      final database = _required();
      await database.execute(
        'UPDATE ${quoteIdent(table)} SET ${quoteIdent(column)} = ? '
        'WHERE rowid = ?',
        [value, rowid],
      );
      dirty = true;
      notifyListeners();
    });
  }

  /// Deletes the row with this rowid.
  Future<void> deleteRow(String table, BigInt rowid) {
    return _enqueue(() async {
      final database = _required();
      await database.execute(
        'DELETE FROM ${quoteIdent(table)} WHERE rowid = ?',
        [rowid],
      );
      dirty = true;
      notifyListeners();
    });
  }

  /// Inserts one default row.
  Future<void> insertDefault(String table) {
    return _enqueue(() async {
      final database = _required();
      await database.execute('INSERT INTO ${quoteIdent(table)} DEFAULT VALUES');
      dirty = true;
      notifyListeners();
    });
  }

  /// Releases the image.
  Future<void> close() {
    return _enqueue(() async {
      final previous = _database;
      _database = null;
      objects = const [];
      await previous?.close();
      notifyListeners();
    });
  }

  Future<void> _adopt(MutableSqliteDatabase next, String nextLabel) async {
    final previous = _database;
    _database = next;
    label = nextLabel;
    dirty = false;
    await _loadSchema(next);
    await previous?.close();
    notifyListeners();
  }

  Future<StatementResult> _run(
      MutableSqliteDatabase database, String text) async {
    final words = sqlWords(text);
    final read = statementReads(text);
    if (read && words.isNotEmpty && words.first == 'pragma') {
      try {
        return await _query(database, text);
      } on SqlException {
        return _write(database, text);
      }
    }
    if (read) return _query(database, text);
    return _write(database, text);
  }

  Future<StatementResult> _query(
      MutableSqliteDatabase database, String text) async {
    final result = await database.query(text);
    return StatementResult.query(result.columns, result.rows);
  }

  Future<StatementResult> _write(
      MutableSqliteDatabase database, String text) async {
    final result = await database.execute(text);
    return StatementResult.write(result.changes, result.lastInsertRowid);
  }

  Future<void> _loadSchema(MutableSqliteDatabase database) async {
    final result = await database.query(
      'SELECT type, name, tbl_name, sql FROM sqlite_schema '
      "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
    );
    objects = [
      for (final row in result.rows)
        SchemaObject(
          type: row[0]! as String,
          name: row[1]! as String,
          table: (row[2] as String?) ?? row[1]! as String,
          sql: row[3] as String?,
        ),
    ];
  }

  Future<List<ColumnInfo>> _columns(
      MutableSqliteDatabase database, String table) async {
    final result = await database.query(
      'PRAGMA table_info(${pragmaIdent(table)})',
    );
    return [
      for (final row in result.rows)
        ColumnInfo(
          name: row[1]! as String,
          type: (row[2] as String?) ?? '',
          notNull: _flag(row[3]),
          primaryKey: _flag(row[5]),
        ),
    ];
  }

  MutableSqliteDatabase _required() {
    final database = _database;
    if (database == null) throw StateError('No database is open');
    return database;
  }

  Future<T> _enqueue<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }
}

bool _flag(Object? value) => value == BigInt.one || value == 1 || value == true;

int _asInt(Object? value) {
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  throw FormatException('Expected an integer count, got $value');
}
