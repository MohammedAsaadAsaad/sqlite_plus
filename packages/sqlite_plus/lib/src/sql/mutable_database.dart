import 'dart:typed_data';

import '../btree/btree_reader.dart';
import '../btree/table_image_writer.dart';
import '../pager/read_only_pager.dart';
import '../pager/rollback_journal_pager.dart';
import '../storage/memory_storage_backend.dart';
import 'catalog.dart';
import 'database.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class MutationResult {
  const MutationResult(this.changes, this.lastInsertRowid);
  final int changes;
  final BigInt? lastInsertRowid;
}

/// Experimental M4 image writer for ordinary, unconstrained, unindexed rowid
/// tables. In-memory by default. An explicitly durable pager can commit images.
/// No concurrent calls, SQL transaction statements, indexes, triggers or WAL.
final class MutableSqliteDatabase {
  MutableSqliteDatabase._(this._image, this._journal);
  Uint8List _image;
  final RollbackJournalPager? _journal;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;
  static Future<MutableSqliteDatabase> fromImage(Uint8List image) async {
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final database = await SqliteDatabase.openReadOnly(storage);
    await database.close();
    return MutableSqliteDatabase._(Uint8List.fromList(image), null);
  }

  static Future<MutableSqliteDatabase> fromJournalPager(
          RollbackJournalPager pager) async =>
      MutableSqliteDatabase._(await pager.readImage(), pager);
  Uint8List exportImage() {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    return Uint8List.fromList(_image);
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final storage = MemoryStorageBackend();
        await storage.write(0, _image);
        final reader = await SqliteDatabase.openReadOnly(storage);
        try {
          return await reader.query(sql, parameters);
        } finally {
          await reader.close();
        }
      });
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final parser = SqlParser(sql);
        final insert = parser.take('INSERT');
        final update = !insert && parser.take('UPDATE');
        if (!insert && !update) parser.require('DELETE');
        if (insert) parser.require('INTO');
        if (!insert && !update) parser.require('FROM');
        final tableName = parser.identifier();
        final storage = MemoryStorageBackend();
        await storage.write(0, _image);
        final pager = await ReadOnlyPager.open(storage);
        try {
          final catalog = await DatabaseCatalog.read(pager);
          final table = catalog.table(tableName);
          final definition = catalog.entries
              .where((e) => asciiLower(e.name) == asciiLower(tableName))
              .firstOrNull;
          if (definition == null ||
              table.withoutRowid ||
              table.rootPage == 1 ||
              RegExp(r'\b(NOT|UNIQUE|CHECK|REFERENCES|DEFAULT|COLLATE|AUTOINCREMENT|GENERATED|CONSTRAINT)\b',
                      caseSensitive: false)
                  .hasMatch(definition.sql!) ||
              catalog.entries.any((e) =>
                  asciiLower(e.tableName) == asciiLower(tableName) &&
                  e.type != 'table')) {
            throw UnsupportedError(
                'M4 mutations require a simple unindexed rowid table without constraints');
          }
          final names = table.columns.map((c) => asciiLower(c.name)).toList();
          final rowNames = {...names, 'rowid', '_rowid_', 'oid'};
          final affinities = {
            for (final c in table.columns) asciiLower(c.name): c.affinity
          };
          final inputs = <String>[];
          final values = <List<Expr>>[];
          final assignments = <String, Expr>{};
          Expr? where;
          if (insert) {
            if (parser.take('(')) {
              do {
                inputs.add(asciiLower(parser.identifier()));
              } while (parser.take(','));
              parser.require(')');
            } else {
              inputs.addAll(names);
            }
            if (inputs.toSet().length != inputs.length ||
                inputs.any((n) => !rowNames.contains(n))) {
              throw const SqlException('Invalid INSERT columns');
            }
            parser.require('VALUES');
            do {
              parser.require('(');
              final row = <Expr>[];
              do {
                final expr = parser.expression();
                expr.validate({});
                row.add(expr);
              } while (parser.take(','));
              parser.require(')');
              if (row.length != inputs.length) {
                throw const SqlException('INSERT width mismatch');
              }
              values.add(row);
            } while (parser.take(','));
          } else {
            if (update) {
              parser.require('SET');
              do {
                final name = asciiLower(parser.identifier());
                if (!rowNames.contains(name) || assignments.containsKey(name)) {
                  throw const SqlException('Invalid UPDATE column');
                }
                parser.require('=');
                final expr = parser.expression();
                expr.validate(rowNames);
                assignments[name] = expr;
              } while (parser.take(','));
            }
            if (parser.take('WHERE')) {
              where = parser.expression();
              where.validate(rowNames);
            }
          }
          parser.finish();
          if (parameters.length != parser.parameterCount) {
            throw const SqlException('Incorrect parameter count');
          }
          final bound = parameters.map(sqlValue).toList();
          final rows = <TableRow>[];
          await for (final record
              in BtreeReader(pager).scanTable(table.rootPage)) {
            rows.add(TableRow(record.rowId!, record.values));
          }
          RowValues rowMap(TableRow row) {
            final result = <String, Object?>{};
            for (var i = 0; i < names.length; i++) {
              result[names[i]] = table.columns[i].name == table.rowidAlias
                  ? row.rowId
                  : row.values[i];
            }
            for (final n in ['rowid', '_rowid_', 'oid']) {
              result.putIfAbsent(n, () => row.rowId);
            }
            return result;
          }

          BigInt rowId(Object? value) {
            value = value is String ? numeric(value) : value;
            if (value is double &&
                value.isFinite &&
                value == value.truncateToDouble()) {
              value = BigInt.from(value);
            }
            if (value is! BigInt ||
                value < -(BigInt.one << 63) ||
                value >= BigInt.one << 63) {
              throw const SqlException('Rowid datatype mismatch');
            }
            return value;
          }

          Object? stored(Object? value, CatalogColumn column) {
            value = applyAffinity(value, column.affinity);
            if (column.affinity == 'numeric' &&
                value is double &&
                value.isFinite &&
                value == value.truncateToDouble() &&
                value >= -(BigInt.one << 63).toDouble() &&
                value < (BigInt.one << 63).toDouble()) {
              value = BigInt.from(value);
            }
            return value;
          }

          TableRow physical(RowValues row, BigInt id) => TableRow(id, [
                for (final column in table.columns)
                  column.name == table.rowidAlias
                      ? null
                      : stored(row[asciiLower(column.name)], column)
              ]);
          var changes = 0;
          BigInt? last;
          final next = <TableRow>[];
          if (insert) {
            next.addAll(rows);
            for (final input in values) {
              final ctx = EvalContext({}, {}, bound, pager.header.textEncoding);
              final data = <String, Object?>{};
              for (var i = 0; i < inputs.length; i++) {
                data[inputs[i]] = input[i].evaluate(ctx);
              }
              Object? requested = table.rowidAlias == null
                  ? null
                  : data[asciiLower(table.rowidAlias!)];
              for (final n in ['rowid', '_rowid_', 'oid']) {
                if (!names.contains(n) && data.containsKey(n)) {
                  requested = data[n];
                }
              }
              final max = next.fold<BigInt>(
                  BigInt.zero, (a, r) => r.rowId > a ? r.rowId : a);
              final id =
                  requested == null ? max + BigInt.one : rowId(requested);
              if (id >= BigInt.one << 63) {
                throw const SqlException('Automatic rowid exhausted');
              }
              next.add(physical(data, id));
              last = id;
              changes++;
            }
          } else {
            for (final row in rows) {
              final data = rowMap(row);
              final ctx = EvalContext(
                  data, affinities, bound, pager.header.textEncoding);
              if (where != null &&
                  truth(where.evaluate(ctx), pager.header.textEncoding) !=
                      true) {
                next.add(row);
                continue;
              }
              changes++;
              if (update) {
                final updated = {...data};
                for (final entry in assignments.entries) {
                  updated[entry.key] = entry.value.evaluate(ctx);
                }
                var id = row.rowId;
                if (table.rowidAlias != null &&
                    assignments.containsKey(asciiLower(table.rowidAlias!))) {
                  id = rowId(updated[asciiLower(table.rowidAlias!)]);
                }
                for (final n in ['rowid', '_rowid_', 'oid']) {
                  if (!names.contains(n) && assignments.containsKey(n)) {
                    id = rowId(updated[n]);
                  }
                }
                next.add(physical(updated, id));
              }
            }
          }
          if (changes == 0) return MutationResult(0, null);
          final image = await TableImageWriter.replace(_image, tableName, next);
          if (_journal != null) {
            try {
              await _journal.commitImage(image);
            } catch (_) {
              _failed = true;
              rethrow;
            }
          }
          _image = image;
          return MutationResult(changes, last);
        } finally {
          await pager.close();
        }
      });
  Future<void> close() async {
    if (_busy) throw StateError('Database operation in progress');
    if (_closed) return;
    _closed = true;
    await _journal?.close();
  }
}
