import 'dart:typed_data';
import 'dart:convert';

import '../btree/btree_reader.dart';
import '../btree/database_image_builder.dart';
import '../btree/page_patch.dart';
import '../btree/rowid_page_patch.dart';
import '../btree/table_image_writer.dart';
import '../format/database_header.dart';
import '../pager/read_only_pager.dart';
import '../storage/memory_storage_backend.dart';
import 'catalog.dart';
import 'database.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'triggers.dart';
import 'function_registry.dart';
import 'values.dart';
import 'index_definition.dart';
import 'schema_rewriter.dart';
import 'column_rewriter.dart';
import 'expressions.dart';
import 'connection_state.dart';
import 'functions.dart';
import 'windows.dart';
import 'fts5_format.dart';
import 'fts_text.dart';
import 'geopoly.dart';
import 'search_modules.dart';
import 'search_runtime.dart';
import 'virtual_table.dart';

part 'image_maintenance.dart';
part 'search_mutations.dart';

final class MutationImage {
  MutationImage(this.image, this.changes, this.lastRowid, [this.returning]);
  final QueryResult? returning;
  final Uint8List image;
  final int changes;
  final BigInt? lastRowid;
}

/// A failed SQL statement may retain prior work (FAIL), or roll back its owner
/// transaction. Only the mutable connection can apply that commit boundary.
final class MutationFailure implements Exception {
  MutationFailure(this.error,
      {this.partialImage, this.rollbackTransaction = false});
  final SqlException error;
  final Uint8List? partialImage;
  final bool rollbackTransaction;
}

final class _Table {
  _Table(this.schema, this.sql, this.rows, {this.view = false});
  final bool view;
  final CatalogTable schema;
  final String sql;
  final List<TableRow> rows;

  /// Unique rowids and index keys for the current [rows]. Inserts update this
  /// in place. Any other row edit clears it.
  Set<BigInt>? residentRowids;
  List<String>? residentKeyIds;
  Map<String, Set<String>>? residentUniques;

  /// Uniform integer increments not yet written into [rows]. Readers apply or
  /// flush this before using a stored value.
  Map<int, BigInt>? columnAddends;
  Map<BigInt, TableRow>? rowById;
  Map<int, Map<Object, List<TableRow>>>? valueIndexes;

  void invalidateResidentKeys() {
    residentRowids = null;
    residentKeyIds = null;
    residentUniques = null;
    rowById = null;
    valueIndexes = null;
  }
}

final class _FastInsertPlan {
  _FastInsertPlan({
    required this.tableKey,
    required this.token,
    required this.rowidParameter,
    required this.parameters,
    required this.columns,
    required this.arity,
  });

  final String tableKey;
  final int token;
  final int rowidParameter;
  final List<int> parameters;
  final List<int> columns;
  final int arity;
}

final class _Index {
  _Index(this.name, this.table, this.columns, this.descending, this.collations,
      this.unique, this.sql,
      {this.definition});
  final String name, table;
  final List<String> columns;
  final List<bool> descending;
  final List<String> collations;
  final bool unique;
  final String? sql;
  final IndexDefinition? definition;
  bool get parentKey =>
      definition?.predicate == null &&
      (definition == null ||
          definition!.terms.every((t) => t.columnName != null));
  Set<String> get referencedColumns =>
      definition?.referencedColumns ?? columns.map(asciiLower).toSet();
}

final class _Upsert {
  _Upsert(this.target, this.index, this.nothing, this.assignments, this.where);
  final List<Expr>? target;
  final _Index? index; // null with a target denotes the rowid key.
  final bool nothing;
  final Map<String, Expr> assignments;
  final Expr? where;
}

/// In-memory tables, indexes, and rows captured so a later rollback can
/// return to that logical database without a byte image.
final class LogicalImage {
  LogicalImage(this._tables, this._rows, this._indexes, this._other,
      this._sequences, this._schemaChanged, this._addends);
  final Map<String, _Table> _tables;
  final Map<String, List<TableRow>> _rows;
  final List<_Index> _indexes;
  final List<ImageObject> _other;
  final Map<String, BigInt> _sequences;
  final bool _schemaChanged;
  final Map<String, Map<int, BigInt>> _addends;
}

/// Validates complete logical mutations before compact image reconstruction.
/// File atomicity remains the responsibility of ImagePager.
final class ImageMutations {
  ImageMutations._(this.original, this.encoding);
  Uint8List original;

  /// When set, ordinary DML keeps the changed rows and skips the image rebuild.
  /// The connection materializes those rows on read, export, or schema change.
  bool deferMaterialize = false;

  /// True when the latest statement changed stored rows and left the image stale.
  bool wroteRows = false;

  /// A whole-table delete of an ordinary rowid table should put the old leaf
  /// pages on the freelist before the statement returns. Constrained tables
  /// leave this false and compact on the next read.
  bool releaseFreedPages = false;

  /// Rebuilds one ordinary table in place. Null means the compact serializer
  /// has to run later.
  Future<Uint8List?> releaseFreedPagesImage() {
    return _tryIncremental(foreignKeys: false, includeDeferred: false);
  }

  LogicalImage captureLogical() => LogicalImage(
      Map<String, _Table>.of(_tables),
      {
        for (final entry in _tables.entries)
          entry.key: List<TableRow>.of(entry.value.rows)
      },
      List<_Index>.of(_indexes),
      List<ImageObject>.of(other),
      Map<String, BigInt>.of(_sequences),
      schemaChanged,
      {
        for (final entry in _tables.entries)
          if (entry.value.columnAddends != null)
            entry.key: Map<int, BigInt>.of(entry.value.columnAddends!)
      });

  void restoreLogical(LogicalImage snapshot) {
    schemaChanged = snapshot._schemaChanged;
    _tables
      ..clear()
      ..addAll(snapshot._tables);
    _indexes
      ..clear()
      ..addAll(snapshot._indexes);
    other
      ..clear()
      ..addAll(snapshot._other);
    _sequences
      ..clear()
      ..addAll(snapshot._sequences);
    for (final entry in _tables.entries) {
      final rows = snapshot._rows[entry.key] ?? const <TableRow>[];
      entry.value.rows
        ..clear()
        ..addAll(rows);
      final addends = snapshot._addends[entry.key];
      entry.value.columnAddends =
          addends == null ? null : Map<int, BigInt>.of(addends);
      entry.value.invalidateResidentKeys();
    }
    _loadedRows.clear();
  }

  /// Plain row changes can wait for the next read. Generated columns, views,
  /// and triggers publish their image immediately so the following statement
  /// sees the same pages as a per-statement rebuild.
  bool get _canDeferImage {
    if (schemaChanged || other.isNotEmpty) return false;
    // Expression indexes and generated columns are rebuilt from the byte image.
    // Publishing each statement keeps REINDEX and the next read on that image.
    if (_indexes.any((index) => index.sql != null)) return false;
    for (final table in _tables.values) {
      if (table.schema.columns
          .any((column) => column.generatedExpression != null)) {
        return false;
      }
    }
    return true;
  }

  /// Treat [image] as the serialized form of the current rows.
  ///
  /// The loaded snapshot shares row instances. Later edits replace list
  /// entries, so the snapshot still identifies the rows the image contains.
  void rebase(Uint8List image) {
    original = image;
    schemaChanged = false;
    for (final entry in _tables.entries) {
      _loadedRows[entry.key] = List<TableRow>.of(entry.value.rows);
    }
  }

  final int encoding;
  final Map<String, _Table> _tables = {};
  final List<_Index> _indexes = [];
  final List<ImageObject> other = [];
  bool schemaChanged = false;
  final Map<String, BigInt> _sequences = {};
  final Map<String, List<TableRow>> _loadedRows = {};
  static Future<ImageMutations> load(Uint8List image) async {
    final header = DatabaseHeader.decode(image);
    final result = ImageMutations._(image, header.textEncoding);
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final pager = await ReadOnlyPager.open(storage);
    try {
      if (image.length > 64 * 1024 * 1024 ||
          !header.hasValidDatabaseSize ||
          header.databaseSize * header.pageSize != image.length ||
          header.largestRootPage != 0 ||
          header.reservedBytes != 0) {
        throw UnsupportedError(
            'Writer requires complete non-auto-vacuum image without reserved bytes');
      }
      final catalog = await DatabaseCatalog.read(pager);
      final owned = <int>{};
      for (final root in [
        1,
        ...catalog.entries.where((e) => e.rootPage != 0).map((e) => e.rootPage)
      ]) {
        final first = await pager.readPage(root);
        final reader = BtreeReader(pager, onPageRead: (number) {
          if (!owned.add(number)) {
            throw const FormatException('Cross-tree page alias');
          }
        });
        await ([5, 13].contains(first[root == 1 ? 100 : 0])
                ? reader.scanTable(root)
                : reader.scanIndex(root))
            .drain<void>();
      }
      var trunk = header.firstFreelistTrunk;
      var freeCount = 0;
      while (trunk != 0) {
        if (trunk < 2 || !owned.add(trunk)) {
          throw const FormatException('Invalid freelist trunk');
        }
        final bytes = ByteData.sublistView(await pager.readPage(trunk));
        final count = bytes.getUint32(4);
        if (count > header.usableSize ~/ 4 - 2) {
          throw const FormatException('Invalid freelist count');
        }
        freeCount++;
        for (var i = 0; i < count; i++) {
          final page = bytes.getUint32(8 + 4 * i);
          if (page < 2 || page > pager.pageCount || !owned.add(page)) {
            throw const FormatException('Invalid freelist leaf');
          }
          freeCount++;
        }
        trunk = bytes.getUint32(0);
      }
      if (freeCount != header.freelistPages ||
          owned.length != pager.pageCount) {
        throw const FormatException('Freelist count mismatch or unowned pages');
      }
      for (final entry
          in catalog.entries.where((entry) => entry.type == 'table')) {
        if (entry.rootPage == 0 &&
            VirtualTableDeclaration.isVirtual(entry.sql)) {
          result.other.add(ImageObject(
              'table', entry.name, entry.tableName, entry.sql,
              virtualTable: true));
          continue;
        }
        final table = catalog.table(entry.name);
        final rows = <TableRow>[];
        await for (final record in table.withoutRowid
            ? BtreeReader(pager).scanIndex(table.rootPage)
            : BtreeReader(pager).scanTable(table.rootPage)) {
          final values = List<Object?>.filled(table.columns.length, null);
          final stored = table.storageColumns;
          for (var i = 0; i < stored.length; i++) {
            values[table.columns.indexOf(stored[i])] = i < record.values.length
                ? record.values[i]
                : stored[i].defaultValue;
          }
          rows.add(
              TableRow(record.rowId ?? BigInt.from(rows.length + 1), values));
        }
        result._tables[asciiLower(table.name)] =
            _Table(table, entry.sql!, rows);
      }
      for (final entry
          in catalog.entries.where((entry) => entry.type == 'index')) {
        if (entry.sql != null) {
          result._indexes.add(result._parseIndex(entry.sql!));
        } else {
          final table = result._tables[asciiLower(entry.tableName)]!;
          final definitions = result._implicitKeys(table.schema);
          final suffix = int.tryParse(entry.name.split('_').last);
          if (suffix == null || suffix < 1 || suffix > definitions.length) {
            throw const SqlException('Unsupported automatic index definition');
          }
          final cols = definitions[suffix - 1];
          result._indexes.add(_Index(
              entry.name,
              entry.tableName,
              cols,
              table.schema.autoIndexDescending[suffix - 1],
              table.schema.autoIndexCollations[suffix - 1],
              true,
              null));
        }
      }
      for (final entry in catalog.entries
          .where((entry) => !['table', 'index'].contains(entry.type))) {
        result.other.add(
            ImageObject(entry.type, entry.name, entry.tableName, entry.sql));
      }
      final sequence = result._tables['sqlite_sequence'];
      if (sequence != null) {
        for (final row in sequence.rows) {
          final values = result._row(sequence, row);
          if (values['name'] is String && values['seq'] is BigInt) {
            result._sequences[asciiLower(values['name'] as String)] =
                values['seq'] as BigInt;
          }
        }
      }
      for (final entry in result._tables.entries) {
        result._loadedRows[entry.key] = List<TableRow>.of(entry.value.rows);
      }
      return result;
    } finally {
      await pager.close();
    }
  }

  /// Checks supported physical trees and compares persisted index records with
  /// records rebuilt from the table contents. The caller's image is unchanged.
  static Future<List<String>> integrity(Uint8List image,
      {bool quick = false}) async {
    final pagers = <ReadOnlyPager>[];
    try {
      final state = await load(image);
      state._validate();
      if (quick) return ['ok'];
      final expected = state.serialize();
      for (final bytes in [image, expected]) {
        final storage = MemoryStorageBackend();
        await storage.write(0, bytes);
        pagers.add(await ReadOnlyPager.open(storage));
      }
      final catalogs = [
        await DatabaseCatalog.read(pagers[0]),
        await DatabaseCatalog.read(pagers[1])
      ];
      for (final entry in catalogs[0].entries.where((e) =>
          e.type == 'index' ||
          e.type == 'table' && catalogs[0].table(e.name).withoutRowid)) {
        final other = catalogs[1].entries.firstWhere((e) =>
            e.type == entry.type &&
            asciiLower(e.name) == asciiLower(entry.name));
        final actual =
            await BtreeReader(pagers[0]).scanIndex(entry.rootPage).toList();
        final rebuilt =
            await BtreeReader(pagers[1]).scanIndex(other.rootPage).toList();
        if (actual.length != rebuilt.length) {
          return ['Index entry count mismatch: ${entry.name}'];
        }
        for (var i = 0; i < actual.length; i++) {
          final values = actual[i].values.toList();
          if (entry.type == 'table') {
            final columns = catalogs[0].table(entry.name).storageColumns;
            while (values.length < columns.length) {
              values.add(columns[values.length].defaultValue);
            }
          }
          if (values.length != rebuilt[i].values.length) {
            return ['Index record width mismatch: ${entry.name}'];
          }
          for (var j = 0; j < values.length; j++) {
            if (compareValues(
                    values[j], rebuilt[i].values[j], state.encoding) !=
                0) {
              return ['Index content or ordering mismatch: ${entry.name}'];
            }
          }
        }
      }
      return ['ok'];
    } on FormatException catch (error) {
      return [error.message.toString()];
    } on SqlException catch (error) {
      return [error.message];
    } finally {
      for (final pager in pagers) {
        await pager.close();
      }
    }
  }

  QueryResult foreignKeyCheck([String? tableName]) {
    if (tableName != null && !_tables.containsKey(asciiLower(tableName))) {
      throw const SqlException('No such table');
    }
    final failures = <List<Object?>>[];
    for (final table in _tables.values.toList().reversed.where((t) =>
        tableName == null ||
        asciiLower(t.schema.name) == asciiLower(tableName))) {
      final keys = table.schema.foreignKeys.reversed.toList();
      for (final fk in keys) {
        final parent = _tables[asciiLower(fk.table)];
        if (parent == null) continue;
        final pk = parent.schema.columns
            .where((c) => c.primaryKey != 0)
            .toList()
          ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
        final target = fk.targetColumns.isEmpty
            ? pk.map((c) => c.name).toList()
            : fk.targetColumns;
        final names = target.map(asciiLower).toSet();
        final primary = parent.schema.matchesForeignKeyPrimary(target,
            implicit: fk.targetColumns.isEmpty);
        final unique = _indexes.any((index) =>
            index.unique &&
            index.parentKey &&
            asciiLower(index.table) == asciiLower(parent.schema.name) &&
            index.columns.length == target.length &&
            index.columns.map(asciiLower).toSet().containsAll(names) &&
            List.generate(
                    index.columns.length,
                    (i) =>
                        index.collations[i] ==
                        _column(parent.schema, index.columns[i]).collation)
                .every((v) => v));
        if (target.length != fk.columns.length || !primary && !unique) {
          throw const SqlException('Foreign key mismatch');
        }
      }

      final rows = table.rows.toList()
        ..sort((a, b) => a.rowId.compareTo(b.rowId));
      for (final row in rows) {
        for (var i = 0; i < keys.length; i++) {
          final fk = keys[i];
          final key = _key(table, row, fk.columns);
          if (key.any((v) => v == null)) continue;
          final parent = _tables[asciiLower(fk.table)];
          final pk =
              parent?.schema.columns.where((c) => c.primaryKey != 0).toList() ??
                  <CatalogColumn>[];
          pk.sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
          final target = fk.targetColumns.isEmpty
              ? pk.map((c) => c.name).toList()
              : fk.targetColumns;
          if (parent != null && target.length != key.length) {
            throw const SqlException('Foreign key mismatch');
          }
          final found = parent != null &&
              parent.rows.any((p) {
                final values = _key(parent, p, target);
                for (var j = 0; j < key.length; j++) {
                  final col = _column(parent.schema, target[j]);
                  if (compareValues(
                          applyAffinity(key[j], col.affinity),
                          values[j],
                          encoding,
                          parent.schema.foreignKeyCollation(target[j],
                              implicit: fk.targetColumns.isEmpty)) !=
                      0) {
                    return false;
                  }
                }
                return true;
              });
          if (!found) {
            failures.add([
              table.schema.name,
              table.schema.withoutRowid ? null : row.rowId,
              fk.table,
              BigInt.from(i)
            ]);
          }
        }
      }
    }
    return QueryResult(['table', 'rowid', 'parent', 'fkid'], failures);
  }

  CatalogColumn _column(CatalogTable table, String name) {
    final column = table.columns
        .where((c) => asciiLower(c.name) == asciiLower(name))
        .firstOrNull;
    if (column == null) throw SqlException('No such column: $name');
    return column;
  }

  List<List<String>> _implicitKeys(CatalogTable table) => table.autoIndexKeys;

  void _checkForeignKeyParentAction(CatalogTable parent, ForeignKey fk) {
    if (fk.targetColumns.isEmpty &&
        parent.rowidAlias == null &&
        parent.columns.where((column) => column.primaryKey != 0).any((column) =>
            column.collation !=
            parent.primaryKeyCollations[column.primaryKey - 1])) {
      throw const SqlException(
          'Parent actions with overridden primary-key collations are unsupported');
    }
  }

  void _prepareForeignKeys(_Table table, String event,
      {Set<String> updated = const {}, bool replacing = false}) {
    final changed = updated.map(asciiLower).toSet();
    void validate(ForeignKey fk) {
      final parent = _tables[asciiLower(fk.table)];
      if (parent == null) {
        throw SqlException('No such referenced table: ${fk.table}');
      }
      final primary = parent.schema.columns
          .where((column) => column.primaryKey != 0)
          .toList()
        ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
      final target = fk.targetColumns.isEmpty
          ? primary.map((column) => column.name).toList()
          : fk.targetColumns;
      final names = target.map(asciiLower).toSet();
      final valid = parent.schema.matchesForeignKeyPrimary(target,
              implicit: fk.targetColumns.isEmpty) ||
          _indexes.any((index) =>
              index.unique &&
              index.parentKey &&
              asciiLower(index.table) == asciiLower(parent.schema.name) &&
              index.columns.length == target.length &&
              index.columns.map(asciiLower).toSet().containsAll(names) &&
              List.generate(
                      index.columns.length,
                      (i) =>
                          index.collations[i] ==
                          _column(parent.schema, index.columns[i]).collation)
                  .every((value) => value));
      if (target.length != fk.columns.length || !valid) {
        throw const SqlException('Foreign key mismatch');
      }
    }

    for (final fk in table.schema.foreignKeys) {
      if (event != 'UPDATE' ||
          fk.columns.any((column) => changed.contains(asciiLower(column)))) {
        validate(fk);
      }
    }
    if (event == 'INSERT' && !replacing) return;
    for (final child in _tables.values) {
      for (final fk in child.schema.foreignKeys) {
        if (asciiLower(fk.table) != asciiLower(table.schema.name)) continue;
        final target = fk.targetColumns.isEmpty
            ? table.schema.columns
                .where((column) => column.primaryKey != 0)
                .map((column) => column.name)
            : fk.targetColumns;
        if (event != 'UPDATE' ||
            replacing ||
            target.any((column) => changed.contains(asciiLower(column)))) {
          _checkForeignKeyParentAction(table.schema, fk);
          validate(fk);
        }
      }
    }
  }

  String _indexPolicy(_Index index) {
    final schema = _tables[asciiLower(index.table)]!.schema;
    if (index.name == '@pk') return schema.primaryPolicy;
    if (index.sql != null) return 'ABORT';
    final ordinal = int.tryParse(index.name.split('_').last);
    return ordinal != null &&
            ordinal > 0 &&
            ordinal <= schema.autoIndexPolicies.length
        ? schema.autoIndexPolicies[ordinal - 1]
        : 'ABORT';
  }

  _Index _parseIndex(String sql) {
    final p = SqlParser(sql);
    p.require('CREATE');
    p.take('UNIQUE');
    p.require('INDEX');
    if (p.take('IF')) {
      p.require('NOT');
      p.require('EXISTS');
    }
    p.identifier();
    p.require('ON');
    final tableName = p.identifier();
    final table = _tables[asciiLower(tableName)];
    if (table == null) throw const SqlException('No such table');
    final definition = IndexDefinition.parse(sql, table.schema);
    return _Index(
        definition.name,
        definition.table,
        definition.terms.map((t) => t.columnName ?? '').toList(),
        definition.terms.map((t) => t.descending).toList(),
        definition.terms.map((t) => t.collation).toList(),
        definition.unique,
        sql,
        definition: definition);
  }

  bool _includes(_Index index, _Table table, TableRow row) {
    final predicate = index.definition?.predicate;
    return predicate == null ||
        truth(
                predicate.evaluate(
                    _context(table, row, [])..schemaExpression = true),
                encoding) ==
            true;
  }

  bool _containsPrimary(
      _Index index, CatalogColumn column, String primaryCollation) {
    for (var i = 0; i < index.columns.length; i++) {
      final name = index.definition == null
          ? index.columns[i]
          : index.definition!.terms[i].columnName;
      if (name != null &&
          asciiLower(name) == asciiLower(column.name) &&
          index.collations[i] == primaryCollation) {
        return true;
      }
    }
    return false;
  }

  List<Object?> _indexKey(_Index index, _Table table, TableRow row) {
    final definition = index.definition;
    if (definition == null) return _key(table, row, index.columns);
    final context = _context(table, row, [])..schemaExpression = true;
    return definition.terms.map((t) => t.expression.evaluate(context)).toList();
  }

  RowValues _row(_Table table, TableRow row) {
    final result = <String, Object?>{
      for (var i = 0; i < table.schema.columns.length; i++)
        asciiLower(table.schema.columns[i].name):
            table.schema.columns[i].name == table.schema.rowidAlias
                ? row.rowId
                : row.values[i]
    };
    for (final column in table.schema.columns) {
      final type = column.declaredType.toUpperCase();
      final key = asciiLower(column.name);
      if (!table.view &&
          !type.contains('INT') &&
          ['REAL', 'FLOA', 'DOUB'].any(type.contains) &&
          result[key] is BigInt) {
        result[key] = (result[key] as BigInt).toDouble();
      }
    }
    if (!table.view && !table.schema.withoutRowid) {
      for (final name in ['rowid', '_rowid_', 'oid']) {
        result.putIfAbsent(name, () => row.rowId);
      }
    }
    table.schema.evaluateGenerated(result, encoding);
    return result;
  }

  final List<EvalContext> _triggerContexts = [];
  final List<SqlRows Function(SelectStatement, EvalContext)?> _subqueries = [];
  final List<Map<String, String>> _targetAliases = [];
  EvalContext _constantContext(List<Object?> parameters) {
    final trigger = _triggerContexts.lastOrNull;
    return EvalContext(
        {...?trigger?.row}, {...?trigger?.affinities}, parameters, encoding)
      ..collations = {...?trigger?.collations}
      ..subquery = _subqueries.lastOrNull
      ..inTrigger = trigger != null;
  }

  EvalContext _context(_Table table, TableRow row, List<Object?> params,
      {bool returning = false}) {
    final values = _row(table, row);
    final tableName = asciiLower(table.schema.name);
    final prefix = returning
        ? tableName
        : _targetAliases.lastOrNull?[tableName] ?? tableName;
    final trigger = _triggerContexts.lastOrNull;
    return EvalContext({
      ...?trigger?.row,
      ...values,
      for (final entry in values.entries) ...{
        '$prefix.${entry.key}': entry.value,
        if (!returning) 'main.$prefix.${entry.key}': entry.value
      }
    }, {
      ...?trigger?.affinities,
      for (final col in table.schema.columns) ...{
        asciiLower(col.name): col.affinity,
        '$prefix.${asciiLower(col.name)}': col.affinity,
        if (!returning) 'main.$prefix.${asciiLower(col.name)}': col.affinity
      }
    }, params, encoding)
      ..inTrigger = trigger != null
      ..subquery = _subqueries.lastOrNull
      ..collations = {
        ...?trigger?.collations,
        for (final col in table.schema.columns) ...{
          asciiLower(col.name): col.collation,
          '$prefix.${asciiLower(col.name)}': col.collation,
          if (!returning) 'main.$prefix.${asciiLower(col.name)}': col.collation
        }
      };
  }

  Object? _stored(Object? value, CatalogColumn column) {
    value = applyAffinity(value, column.affinity);
    if (column.affinity == 'numeric' &&
        value is double &&
        value.isFinite &&
        value == value.truncateToDouble() &&
        value > -(BigInt.one << 63).toDouble() &&
        value < (BigInt.one << 63).toDouble()) {
      value = BigInt.from(value);
    }
    return sqlValue(value);
  }

  TableRow _physical(_Table table, Map<String, Object?> values, BigInt id) {
    final typed = <String, Object?>{
      for (final col in table.schema.columns)
        asciiLower(col.name): col.name == table.schema.rowidAlias
            ? id
            : table.view
                ? values[asciiLower(col.name)]
                : _stored(values[asciiLower(col.name)], col)
    };
    if (!table.view) {
      for (final col in table.schema.columns) {
        final key = asciiLower(col.name), type = col.declaredType.toUpperCase();
        if (typed[key] is BigInt &&
            !type.contains('INT') &&
            ['REAL', 'FLOA', 'DOUB'].any(type.contains)) {
          typed[key] = (typed[key] as BigInt).toDouble();
        }
      }
    }
    table.schema.evaluateGenerated(typed, encoding, recomputeStored: true);
    return TableRow(id, [
      for (final col in table.schema.columns)
        col.name == table.schema.rowidAlias
            ? null
            : table.view
                ? typed[asciiLower(col.name)]
                : _stored(typed[asciiLower(col.name)], col)
    ]);
  }

  int _compare(_Index index, List<Object?> a, List<Object?> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final c = compareValues(a[i], b[i], encoding,
          i < index.collations.length ? index.collations[i] : null);
      if (c != 0) {
        return i < index.descending.length && index.descending[i] ? -c : c;
      }
    }
    return a.length.compareTo(b.length);
  }

  List<Object?> _key(_Table table, TableRow row, List<String> columns) =>
      [for (final name in columns) _row(table, row)[asciiLower(name)]];
  Future<void> _referentialActions(
      _Table parent, TableRow before, TableRow? after, int depth,
      {required bool inTransaction}) async {
    if (depth > 1000) {
      throw const SqlException('Foreign key action depth exceeded');
    }
    for (final child in _tables.values) {
      for (final fk in child.schema.foreignKeys.where(
          (fk) => asciiLower(fk.table) == asciiLower(parent.schema.name))) {
        final pk = parent.schema.columns
            .where((c) => c.primaryKey != 0)
            .toList()
          ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
        final target = fk.targetColumns.isEmpty
            ? pk.map((c) => c.name).toList()
            : fk.targetColumns;
        if (target.length != fk.columns.length) {
          throw const SqlException('Foreign key mismatch');
        }
        final oldKey = _key(parent, before, target);
        final newKey = after == null ? null : _key(parent, after, target);
        if (newKey != null &&
            List.generate(
                oldKey.length,
                (i) =>
                    compareValues(
                        oldKey[i],
                        newKey[i],
                        encoding,
                        parent.schema.foreignKeyCollation(target[i],
                            implicit: fk.targetColumns.isEmpty)) ==
                    0).every((v) => v)) {
          continue;
        }
        _checkForeignKeyParentAction(parent.schema, fk);
        final action = after == null ? fk.onDelete : fk.onUpdate;
        final matches = child.rows.where((row) {
          final values = _key(child, row, fk.columns);
          if (values.any((v) => v == null)) return false;
          return List.generate(
              values.length,
              (i) =>
                  compareValues(
                      applyAffinity(values[i],
                          _column(parent.schema, target[i]).affinity),
                      oldKey[i],
                      encoding,
                      parent.schema.foreignKeyCollation(target[i],
                          implicit: fk.targetColumns.isEmpty)) ==
                  0).every((v) => v);
        }).toList();
        if (matches.isEmpty) continue;
        if (action == 'RESTRICT') {
          throw const SqlConstraintException('FOREIGN KEY constraint failed');
        }
        if (action == 'NO ACTION') continue;
        final counterState = SqlFunctionRegistry.current?.connectionState;
        final savedCounters = counterState?.saveTrigger();
        final counters = counterState?.beginStatement();
        try {
          for (final row in matches) {
            if (!child.rows.contains(row)) continue;
            if (action == 'CASCADE' && after == null) {
              if (!await _fire('BEFORE', 'DELETE', child, row, null, {},
                  foreignKeys: true, inTransaction: inTransaction)) {
                continue;
              }
              child.invalidateResidentKeys();
              child.rows.remove(row);
              await _referentialActions(child, row, null, depth + 1,
                  inTransaction: inTransaction);
              _validate();
              counters?.changed();
              await _fire('AFTER', 'DELETE', child, row, null, {},
                  foreignKeys: true, inTransaction: inTransaction);
            } else {
              final values = _row(child, row);
              for (var i = 0; i < fk.columns.length; i++) {
                values[asciiLower(fk.columns[i])] = action == 'SET NULL'
                    ? null
                    : action == 'SET DEFAULT'
                        ? (_column(child.schema, fk.columns[i])
                                .defaultExpression
                                ?.evaluate(EvalContext({}, {}, [], encoding)) ??
                            _column(child.schema, fk.columns[i]).defaultValue)
                        : newKey![i];
              }
              var id = row.rowId;
              if (child.schema.rowidAlias != null &&
                  fk.columns.any((c) =>
                      asciiLower(c) == asciiLower(child.schema.rowidAlias!))) {
                final value = values[asciiLower(child.schema.rowidAlias!)];
                if (value is! BigInt) {
                  throw const SqlException('Rowid datatype mismatch');
                }
                id = value;
              }
              final changed = _physical(child, values, id);
              final columns = fk.columns.map(asciiLower).toSet();
              if (!await _fire('BEFORE', 'UPDATE', child, row, changed, columns,
                  foreignKeys: true, inTransaction: inTransaction)) {
                continue;
              }
              final position = child.rows.indexOf(row);
              if (position < 0) continue;
              child.invalidateResidentKeys();
              child.rows[position] = changed;
              _validate();
              counters?.changed();
              await _referentialActions(child, row, changed, depth + 1,
                  inTransaction: inTransaction);
              await _fire('AFTER', 'UPDATE', child, row, changed, columns,
                  foreignKeys: true, inTransaction: inTransaction);
            }
          }
          counters?.finish();
        } on SqlTriggerFailure catch (error) {
          counters?.finish(retainChanges: error.action == 'FAIL');
          rethrow;
        } catch (_) {
          counters?.finish(retainChanges: false);
          rethrow;
        } finally {
          if (savedCounters != null) {
            counterState!.restoreTrigger(savedCounters);
          }
        }
      }
    }
  }

  void _validate(
      {bool foreignKeys = false,
      bool includeDeferred = false,
      bool rowConstraints = true}) {
    for (final table in _tables.values) {
      void validateType(CatalogColumn column, Object? value) {
        if (!column.strict || value == null) return;
        final type = column.declaredType.toUpperCase();
        final valid = type == 'ANY' ||
            ['INT', 'INTEGER'].contains(type) && value is BigInt ||
            type == 'REAL' && (value is BigInt || value is double) ||
            type == 'TEXT' && value is String ||
            type == 'BLOB' && value is Uint8List;
        if (!valid) {
          throw const SqlDatatypeConstraint(
              'STRICT datatype constraint failed');
        }
      }

      final seen = <BigInt>{};
      for (final row in rowConstraints ? table.rows : <TableRow>[]) {
        if (!seen.add(row.rowId)) {
          throw const SqlConstraintException('UNIQUE constraint failed: rowid');
        }
        final values = _row(table, row);
        final ctx = _context(table, row, const []);
        for (final col in table.schema.columns) {
          validateType(col, values[asciiLower(col.name)]);
          if ((col.notNull ||
                  (table.schema.withoutRowid ||
                          col.strict && col.name != table.schema.rowidAlias) &&
                      col.primaryKey != 0) &&
              values[asciiLower(col.name)] == null) {
            throw SqlConstraintException(
                'NOT NULL constraint failed: ${table.schema.name}.${col.name}');
          }
        }
        for (final check in [
          ...table.schema.checks,
          ...table.schema.columns.expand((c) => c.checks)
        ]) {
          if (truth(check.evaluate(ctx), encoding) == false) {
            throw const SqlConstraintException('CHECK constraint failed');
          }
        }
      }
      final unique = [
        ..._indexes.where((i) =>
            i.unique && asciiLower(i.table) == asciiLower(table.schema.name))
      ];
      if (table.schema.withoutRowid) {
        final pk = table.schema.columns.where((c) => c.primaryKey != 0).toList()
          ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
        unique.add(_Index(
            '@pk',
            table.schema.name,
            pk.map((c) => c.name).toList(),
            table.schema.primaryKeyDescending,
            table.schema.primaryKeyCollations,
            true,
            null));
      }
      for (final index in unique) {
        final keys = [
          for (final row in table.rows)
            if (_includes(index, table, row)) _indexKey(index, table, row)
        ]..sort((a, b) => _compare(index, a, b));
        for (var i = 1; i < keys.length; i++) {
          if (keys[i].every((v) => v != null) &&
              _compare(index, keys[i - 1], keys[i]) == 0) {
            throw SqlConstraintException(
                'UNIQUE constraint failed: ${index.name}');
          }
        }
      }
      if (foreignKeys) {
        for (final fk in table.schema.foreignKeys) {
          if (fk.deferred && !includeDeferred) continue;
          final parent = _tables[asciiLower(fk.table)];
          for (final row in table.rows) {
            final key = _key(table, row, fk.columns);
            if (key.any((v) => v == null)) continue;
            if (parent == null) {
              throw SqlException('No such referenced table: ${fk.table}');
            }
            final target = fk.targetColumns.isEmpty
                ? (parent.schema.columns
                        .where((c) => c.primaryKey != 0)
                        .toList()
                      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey)))
                    .map((c) => c.name)
                    .toList()
                : fk.targetColumns;
            if (target.length != key.length) {
              throw const SqlException('Foreign key mismatch');
            }
            final normalized = target.map(asciiLower).toSet();
            final validPrimary = parent.schema.matchesForeignKeyPrimary(target,
                implicit: fk.targetColumns.isEmpty);
            final validUnique = _indexes.any((index) =>
                index.unique &&
                index.parentKey &&
                asciiLower(index.table) == asciiLower(parent.schema.name) &&
                index.columns.length == target.length &&
                index.columns.map(asciiLower).toSet().containsAll(normalized) &&
                List.generate(
                        index.columns.length,
                        (i) =>
                            index.collations[i] ==
                            _column(parent.schema, index.columns[i]).collation)
                    .every((v) => v));
            if (!validPrimary && !validUnique) {
              throw const SqlException(
                  'Foreign key mismatch: parent is not unique');
            }
            final exists = parent.rows.any((r) {
              final pkey = _key(parent, r, target);
              for (var i = 0; i < key.length; i++) {
                final col = _column(parent.schema, target[i]);
                if (compareValues(
                        applyAffinity(key[i], col.affinity),
                        pkey[i],
                        encoding,
                        parent.schema.foreignKeyCollation(target[i],
                            implicit: fk.targetColumns.isEmpty)) !=
                    0) {
                  return false;
                }
              }
              return true;
            });
            if (!exists) {
              throw const SqlConstraintException(
                  'FOREIGN KEY constraint failed');
            }
          }
        }
      }
    }
  }

  Future<MutationImage> _createVirtualTable(
      String sql, List<Object?> parameters) async {
    if (parameters.isNotEmpty) {
      throw const SqlException('Parameters prohibited in virtual table');
    }
    final declaration = VirtualTableDeclaration.parse(sql);
    final key = asciiLower(declaration.name);
    if (key.startsWith('sqlite_')) {
      throw const SqlException('Reserved object name');
    }
    final exists = _tables.containsKey(key) ||
        _indexes.any((index) => asciiLower(index.name) == key) ||
        other.any((object) => asciiLower(object.name) == key);
    if (exists) {
      if (declaration.ifNotExists) return MutationImage(original, 0, null);
      throw const SqlException('Object already exists');
    }
    final module = VirtualTableRegistry.current?.find(declaration.module);
    if (module == null) {
      throw SqlException('No such module: ${declaration.module}');
    }
    validateVirtualColumns(module, declaration.name, declaration.arguments,
        declaration.declaredColumns);
    invokeVirtualTableCallback('xCreate',
        () => module.xCreate(declaration.name, declaration.arguments));
    await _installSearchShadows(module, declaration);
    other.add(ImageObject('table', declaration.name, declaration.name, sql,
        virtualTable: true));
    schemaChanged = true;
    return MutationImage(serialize(), 0, null);
  }

  void validateForeignKeys() {
    // A commit checks foreign keys. Tables without one have already enforced
    // NOT NULL, CHECK, and UNIQUE while the statement ran.
    if (_tables.values.every((table) => table.schema.foreignKeys.isEmpty)) {
      return;
    }
    _validate(foreignKeys: true, includeDeferred: true);
  }

  Uint8List serialize(
      {bool foreignKeys = false,
      bool includeDeferred = false,
      bool rowConstraints = true}) {
    _flushColumnAddends();
    _validate(
        foreignKeys: foreignKeys,
        includeDeferred: includeDeferred,
        rowConstraints: rowConstraints);
    final sequence = _tables['sqlite_sequence'];
    if (sequence != null) {
      sequence.invalidateResidentKeys();
      sequence.rows
        ..clear()
        ..addAll([
          for (var i = 0; i < _sequences.length; i++)
            TableRow(BigInt.from(i + 1), [
              _tables[_sequences.keys.elementAt(i)]?.schema.name ??
                  _sequences.keys.elementAt(i),
              _sequences.values.elementAt(i)
            ])
        ]);
    }
    final objects = <ImageObject>[];
    for (final table in _tables.values) {
      final pk = table.schema.columns.where((c) => c.primaryKey != 0).toList()
        ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
      final ordered = table.rows.toList();
      if (table.schema.withoutRowid) {
        ordered.sort((a, b) => _compare(
            _Index(
                '@pk',
                table.schema.name,
                pk.map((c) => c.name).toList(),
                table.schema.primaryKeyDescending,
                table.schema.primaryKeyCollations,
                true,
                null),
            _key(table, a, pk.map((c) => c.name).toList()),
            _key(table, b, pk.map((c) => c.name).toList())));
      }
      objects.add(
          ImageObject('table', table.schema.name, table.schema.name, table.sql,
              tableRows: [
                for (final row in ordered)
                  TableRow(row.rowId, [
                    for (final col in table.schema.storageColumns)
                      row.values[table.schema.columns.indexOf(col)]
                  ])
              ],
              indexTable: table.schema.withoutRowid,
              indexRows: [
                for (final row in ordered)
                  [
                    for (final col in table.schema.storageColumns)
                      _row(table, row)[asciiLower(col.name)]
                  ]
              ]));
    }
    for (final index in _indexes) {
      final table = _tables[asciiLower(index.table)]!;
      final pk = table.schema.columns.where((c) => c.primaryKey != 0).toList()
        ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
      final rows = [
        for (final row in table.rows)
          if (_includes(index, table, row))
            [
              ..._indexKey(index, table, row),
              if (!table.schema.withoutRowid) row.rowId,
              if (table.schema.withoutRowid)
                for (final col in pk)
                  if (!_containsPrimary(index, col,
                      table.schema.primaryKeyCollations[col.primaryKey - 1]))
                    _row(table, row)[asciiLower(col.name)]
            ]
      ];
      final auxiliary = table.schema.withoutRowid
          ? pk
              .where((c) => !_containsPrimary(index, c,
                  table.schema.primaryKeyCollations[c.primaryKey - 1]))
              .toList()
          : <CatalogColumn>[];
      final sorting = _Index(
          index.name,
          index.table,
          index.columns,
          [
            ...index.descending,
            ...auxiliary.map((c) =>
                index.sql != null &&
                table.schema.primaryKeyDescending[c.primaryKey - 1])
          ],
          [
            ...index.collations,
            ...auxiliary
                .map((c) => table.schema.primaryKeyCollations[c.primaryKey - 1])
          ],
          index.unique,
          index.sql);
      rows.sort((a, b) => _compare(sorting, a, b));
      objects.add(ImageObject('index', index.name, index.table, index.sql,
          indexRows: rows));
    }
    objects.addAll(other);
    return DatabaseImageBuilder.build(original, objects,
        schemaChanged: schemaChanged);
  }

  final List<String> _activeTriggers = [];
  bool _recursiveTriggers = false;
  final Set<String> _preparingTriggerPrograms = {};

  void _resolveQueryFunctions(SelectStatement query) {
    for (final name in usedCteNames(query)) {
      _resolveQueryFunctions(query.ctes[name]!.$2);
    }
    for (final source in query.allSources) {
      if (source.query != null) _resolveQueryFunctions(source.query!);
      if (source.on != null) _resolveExpressionFunctions(source.on!);
      for (final argument in source.pragmaArguments ?? const <Expr>[]) {
        _resolveExpressionFunctions(argument);
      }
    }
    for (final expression in [
      ...query.items.map((item) => item.expression),
      query.where,
      ...query.groupBy,
      query.having,
      ...query.order.map((term) => term.expression),
      query.limit,
      query.offset
    ].whereType<Expr>()) {
      _resolveExpressionFunctions(expression);
    }
    for (final part in query.compounds) {
      _resolveQueryFunctions(part.$2);
    }
  }

  void _resolveExpressionFunctions(Expr expression) {
    if (expression is FunctionExpr) expression.resolveSignature();
    if (expression is WindowExpr) {
      expression.function.resolveSignature();
      if (!expression.function.isAggregate &&
          !FunctionExpr.windowNames.contains(expression.function.key)) {
        throw const SqlException('Function cannot be a window');
      }
    }
    if (expression is SubqueryExpr) {
      _resolveQueryFunctions(expression.statement);
    }
    if (expression is InSelectExpr) {
      _resolveQueryFunctions(expression.statement);
    }
    for (final child in expression.children) {
      _resolveExpressionFunctions(child);
    }
  }

  /// Resolve applicable stored programs before evaluating the invoking DML,
  /// including when its WHERE/LIMIT would produce no rows. Merely inspecting
  /// another event's trigger never resolves that trigger's functions.
  Future<void> _prepareTriggerPrograms(
      _Table table, String event, Set<String> changed) async {
    for (final object in other.where((object) =>
        object.type == 'trigger' &&
        asciiLower(object.tableName) == asciiLower(table.schema.name))) {
      final trigger = TriggerDefinition.parse(object.sql!);
      if (trigger.event != event ||
          trigger.columns.isNotEmpty &&
              !trigger.columns.any(changed.contains)) {
        continue;
      }
      final key = asciiLower(trigger.name);
      if (!_preparingTriggerPrograms.add(key)) continue;
      try {
        final values = <String, Object?>{
          for (final prefix in [
            if (event != 'INSERT') 'old',
            if (event != 'DELETE') 'new'
          ])
            for (final column in [
              ...table.schema.columns.map((column) => asciiLower(column.name)),
              if (!table.schema.withoutRowid) ...['rowid', '_rowid_', 'oid']
            ])
              '$prefix.$column': null
        };
        if (trigger.whenSql != null) {
          final bound =
              _bindTrigger('SELECT 1 WHERE (${trigger.whenSql})', values);
          _resolveQueryFunctions(SqlParser(bound.$1).select());
        }
        for (final statement in trigger.statements) {
          final parser = SqlParser(statement);
          if (['SELECT', 'WITH', 'VALUES'].contains(parser.current.keyword)) {
            _resolveQueryFunctions(parser.select());
          } else {
            final bound = _bindTrigger(statement, values);
            await execute(bound.$1, bound.$2, compileOnly: true);
          }
        }
      } finally {
        _preparingTriggerPrograms.remove(key);
      }
    }
  }

  Future<_Table?> _target(String name) async {
    final physical = _tables[asciiLower(name)];
    if (physical != null) return physical;
    final view = other
        .where(
            (o) => o.type == 'view' && asciiLower(o.name) == asciiLower(name))
        .firstOrNull;
    if (view == null) return null;
    final storage = MemoryStorageBackend();
    await storage.write(0, serialize());
    final reader = await SqliteDatabase.openReadOnly(storage,
        functions: SqlFunctionRegistry.current);
    try {
      final escaped = name.replaceAll('"', '""');
      final result = await reader.query('SELECT * FROM "$escaped"');
      final columns = <CatalogColumn>[
        for (var i = 0; i < result.columns.length; i++)
          CatalogColumn(
              result.columns[i],
              result.columnDeclaredTypes[i].isEmpty
                  ? const {
                        'text': 'TEXT',
                        'numeric': 'NUMERIC'
                      }[result.columnAffinities[i]] ??
                      'BLOB'
                  : result.columnDeclaredTypes[i],
              collation: result.columnCollations[i])
      ];
      return _Table(
          CatalogTable(view.name, 0, columns),
          view.sql!,
          [
            for (var i = 0; i < result.rows.length; i++)
              TableRow(BigInt.from(i + 1), result.rows[i])
          ],
          view: true);
    } finally {
      await reader.close();
    }
  }

  Future<QueryResult> _triggerSelect(String sql) async {
    final parsed = SqlParser(sql).select();
    if (parsed.parameterCount != 0) {
      throw const SqlException('Parameters prohibited in trigger SELECT');
    }
    if (parsed.sources.isEmpty &&
        parsed.items.any((item) => item.expression == null)) {
      throw const SqlException('SELECT wildcard requires a source');
    }
    final storage = MemoryStorageBackend();
    await storage.write(0, serialize());
    final reader = await SqliteDatabase.openReadOnly(storage,
        functions: SqlFunctionRegistry.current);
    try {
      return await reader.queryWithContext(sql, [], _triggerContexts.last);
    } finally {
      await reader.close();
    }
  }

  Future<bool> _fire(String timing, String event, _Table table, TableRow? old,
      TableRow? next, Set<String> columns,
      {required bool foreignKeys, required bool inTransaction}) async {
    final definitions = other
        .where((o) =>
            o.type == 'trigger' &&
            asciiLower(o.tableName) == asciiLower(table.schema.name))
        .toList()
        .reversed;
    for (final object in definitions) {
      var trigger = TriggerDefinition.parse(object.sql!);
      final key = asciiLower(trigger.name);
      if (trigger.timing != timing ||
          trigger.event != event ||
          !_recursiveTriggers && _activeTriggers.contains(key) ||
          trigger.columns.isNotEmpty &&
              !trigger.columns.any(columns.contains)) {
        continue;
      }
      trigger =
          TriggerDefinition.parse(object.sql!, deferFunctionResolution: false);
      if (_activeTriggers.length >= 1000) {
        throw const SqlException('Trigger recursion limit');
      }
      final values = <String, Object?>{
        if (old != null)
          for (final entry in _row(table, old).entries)
            'old.${entry.key}': entry.value,
        if (next != null)
          for (final entry in _row(table, next).entries)
            'new.${entry.key}': entry.value,
      };
      if (table.view) {
        for (final prefix in ['old', 'new']) {
          for (final column in table.schema.columns.where((c) =>
              ['REAL', 'FLOA', 'DOUB']
                  .any(c.declaredType.toUpperCase().contains) &&
              !c.declaredType.toUpperCase().contains('INT'))) {
            final key = '$prefix.${asciiLower(column.name)}';
            if (values[key] is BigInt) {
              values[key] = (values[key] as BigInt).toDouble();
            }
          }
        }
      }
      final context = EvalContext(values, {}, [], encoding)..inTrigger = true;
      for (final prefix in ['old', 'new']) {
        for (final column in table.schema.columns) {
          context.affinities['$prefix.${asciiLower(column.name)}'] = 'none';
          context.collations['$prefix.${asciiLower(column.name)}'] =
              column.collation;
        }
        for (final alias in ['rowid', '_rowid_', 'oid']) {
          context.affinities.putIfAbsent('$prefix.$alias', () => 'none');
        }
      }
      _activeTriggers.add(key);
      _triggerContexts.add(context);
      final counterState = SqlFunctionRegistry.current?.connectionState;
      final savedCounters = counterState?.saveTrigger();
      try {
        if (trigger.whenSql != null &&
            (await _triggerSelect('SELECT 1 WHERE (${trigger.whenSql})'))
                .rows
                .isEmpty) {
          continue;
        }
        for (final statement in trigger.statements) {
          final parser = SqlParser(statement);
          if (['SELECT', 'WITH', 'VALUES'].contains(parser.current.keyword)) {
            await _triggerSelect(statement);
          } else {
            await execute(statement, [],
                foreignKeys: foreignKeys, inTransaction: inTransaction);
          }
        }
      } on TriggerIgnore {
        return false;
      } finally {
        if (savedCounters != null) counterState!.restoreTrigger(savedCounters);
        final depth = _activeTriggers.length;
        _activeTriggers.removeLast();
        _triggerContexts.removeLast();
        // Future listeners can unwind synchronously. Break long return/error
        // chains so the SQL depth bound does not become a VM stack overflow.
        if (depth % 32 == 0) await Future<void>.delayed(Duration.zero);
      }
    }
    return true;
  }

  (String, List<Object?>) _bindTrigger(String statement, RowValues values) {
    final parser = SqlParser(statement);
    final tokens = parser.tokens;
    if (tokens.any((t) => t.kind == SqlTokenKind.parameter)) {
      throw const SqlException('Parameters prohibited in trigger SQL');
    }
    final parameters = <Object?>[];
    var rewritten = '';
    var start = 0;
    for (var i = 0; i + 2 < tokens.length; i++) {
      final prefix = asciiLower(tokens[i].text);
      if ((prefix == 'new' || prefix == 'old') && tokens[i + 1].text == '.') {
        final name = '$prefix.${asciiLower(tokens[i + 2].text)}';
        if (!values.containsKey(name)) {
          throw SqlException('No such column: $name');
        }
        parameters.add(values[name]);
        rewritten +=
            '${statement.substring(start, tokens[i].offset)}?${parameters.length}';
        start = tokens[i + 2].offset + tokens[i + 2].text.length;
        // Quoted column names have delimiters beyond token.text.
        if (statement[tokens[i + 2].offset] == '"' ||
            statement[tokens[i + 2].offset] == '`' ||
            statement[tokens[i + 2].offset] == '[') {
          start =
              i + 3 < tokens.length ? tokens[i + 3].offset : statement.length;
        }
        i += 2;
      }
    }
    rewritten += statement.substring(start);
    return (rewritten, parameters);
  }

  String _rewriteIdentifiers(String sql, Map<int, String> replacements,
      {bool quote = true}) {
    var result = '';
    var start = 0;
    for (final token in SqlTokenizer.tokenize(sql)) {
      final replacement = replacements[token.offset];
      if (replacement == null) continue;
      var end = token.offset + token.text.length;
      if (token.quoted) {
        final open = sql[token.offset];
        final close = open == '[' ? ']' : open;
        end = token.offset + 1;
        while (end < sql.length) {
          if (sql[end++] == close) {
            if (end < sql.length && sql[end] == close) {
              end++;
            } else {
              break;
            }
          }
        }
      }
      result += sql.substring(start, token.offset) +
          (quote ? '"${replacement.replaceAll('"', '""')}"' : replacement);
      start = end;
    }
    return result + sql.substring(start);
  }

  String _renameReferences(String sql, String old, String renamed) {
    final tokens = SqlTokenizer.tokenize(sql);
    final replacements = <int, String>{};
    for (var i = 0; i + 1 < tokens.length; i++) {
      if (tokens[i].keyword == 'REFERENCES' &&
          asciiLower(tokens[i + 1].text) == asciiLower(old)) {
        replacements[tokens[i + 1].offset] = renamed;
      }
    }
    return _rewriteIdentifiers(sql, replacements);
  }

  (List<SqlToken>, int, int, List<(int, int)>) _tableParts(String sql) {
    final parser = SqlParser(sql);
    parser.require('CREATE');
    parser.require('TABLE');
    if (parser.take('IF')) {
      parser.require('NOT');
      parser.require('EXISTS');
    }
    parser.identifier();
    parser.require('(');
    final open = parser.position - 1;
    final tokens = parser.tokens;
    var depth = 1, start = parser.position;
    final parts = <(int, int)>[];
    for (var i = start; i < tokens.length; i++) {
      if (tokens[i].kind == SqlTokenKind.symbol && tokens[i].text == '(') {
        depth++;
      }
      if (tokens[i].kind == SqlTokenKind.symbol && tokens[i].text == ')') {
        depth--;
      }
      if (depth == 0) {
        parts.add((start, i));
        return (tokens, open, i, parts);
      }
      if (depth == 1 &&
          tokens[i].kind == SqlTokenKind.symbol &&
          tokens[i].text == ',') {
        parts.add((start, i));
        start = i + 1;
      }
    }
    throw const SqlException('Unterminated table declaration');
  }

  Map<int, String> _referenceColumnReplacements(
      String sql, String parent, String old, String renamed) {
    final tokens = SqlTokenizer.tokenize(sql);
    final replacements = <int, String>{};
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i].keyword != 'REFERENCES' ||
          asciiLower(tokens[i + 1].text) != asciiLower(parent) ||
          tokens[i + 2].text != '(') {
        continue;
      }
      for (var j = i + 3;
          j < tokens.length &&
              !(tokens[j].kind == SqlTokenKind.symbol && tokens[j].text == ')');
          j++) {
        if (tokens[j].kind == SqlTokenKind.identifier &&
            asciiLower(tokens[j].text) == asciiLower(old)) {
          replacements[tokens[j].offset] = renamed;
        }
      }
    }
    return replacements;
  }

  String _renameColumnSql(_Table table, String old, String renamed) {
    final parts = _tableParts(table.sql);
    final tokens = parts.$1;
    final replacements = _referenceColumnReplacements(
        table.sql, table.schema.name, old, renamed);
    void namesIn(int first, int last) {
      for (var i = first; i < last; i++) {
        if (tokens[i].kind != SqlTokenKind.identifier ||
            asciiLower(tokens[i].text) != asciiLower(old)) {
          continue;
        }
        if (i + 1 < last && ['(', '.'].contains(tokens[i + 1].text)) continue;
        if (i > first && ['COLLATE', 'AS'].contains(tokens[i - 1].keyword)) {
          continue;
        }
        replacements[tokens[i].offset] = renamed;
      }
    }

    for (final part in parts.$4) {
      var first = part.$1;
      if (tokens[first].keyword == 'CONSTRAINT') first += 2;
      final constraint = ['PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN']
          .contains(tokens[first].keyword);
      if (!constraint && asciiLower(tokens[first].text) == asciiLower(old)) {
        replacements[tokens[first].offset] = renamed;
      }
      for (var i = first; i < part.$2; i++) {
        final kind = tokens[i].keyword;
        if (kind == 'CHECK' ||
            kind == 'AS' ||
            constraint && ['PRIMARY', 'UNIQUE', 'FOREIGN'].contains(kind)) {
          var open = i + 1;
          while (open < part.$2 &&
              !(tokens[open].kind == SqlTokenKind.symbol &&
                  tokens[open].text == '(')) {
            open++;
          }
          var depth = 1, end = open + 1;
          while (end < part.$2 && depth > 0) {
            if (tokens[end].kind == SqlTokenKind.symbol &&
                tokens[end].text == '(') {
              depth++;
            }
            if (tokens[end].kind == SqlTokenKind.symbol &&
                tokens[end].text == ')') {
              depth--;
            }
            end++;
          }
          namesIn(open + 1, end - 1);
          i = end - 1;
        }
      }
    }
    return _rewriteIdentifiers(table.sql, replacements);
  }

  Map<String, SchemaColumns> get _schemaColumns => {
        for (final entry in _tables.entries)
          entry.key: (
            columns: entry.value.schema.columns.map((c) => c.name).toList(),
            rowid: !entry.value.schema.withoutRowid
          )
      };
  List<DependentSchema> _dependentSchema(List<ImageObject> objects) => [
        for (final object in objects.where((o) => o.sql != null))
          (
            type: object.type,
            name: object.name,
            owner: object.tableName,
            sql: object.sql!
          )
      ];

  final Map<String, _FastInsertPlan> _fastInsertPlans = {};
  int _executionDepth = 0;
  final List<String?> _conflictPolicies = [];
  final List<SqlStatementCounters?> _counterFrames = [];

  void _beginCounters() {
    _counterFrames[_counterFrames.length - 1] ??=
        SqlFunctionRegistry.current?.connectionState.beginStatement();
  }

  void _changed({BigInt? insertedRowid}) =>
      _counterFrames.lastOrNull?.changed(insertedRowid: insertedRowid);

  Future<MutationImage> execute(String sql, List<Object?> parameters,
      {bool foreignKeys = false,
      bool inTransaction = false,
      bool compileOnly = false,
      bool deferTriggerFunctions = false,
      bool? recursiveTriggers}) async {
    final outer = _executionDepth++ == 0;
    if (outer) wroteRows = false;
    _subqueries.add(null);
    _targetAliases.add({});
    _conflictPolicies.add(_conflictPolicies.lastOrNull);
    _counterFrames.add(null);
    try {
      final result = await _execute(sql, parameters,
          foreignKeys: foreignKeys,
          inTransaction: inTransaction,
          compileOnly: compileOnly,
          deferTriggerFunctions: deferTriggerFunctions,
          recursiveTriggers: recursiveTriggers);
      _counterFrames.last?.finish();
      return result;
    } on SqlTriggerFailure catch (error) {
      _counterFrames.last?.finish(retainChanges: error.action == 'FAIL');
      if (!outer) rethrow;
      if (error.action == 'ROLLBACK') {
        throw MutationFailure(error, rollbackTransaction: true);
      }
      throw MutationFailure(error,
          partialImage: serialize(
              foreignKeys: foreignKeys, includeDeferred: !inTransaction));
    } catch (_) {
      _counterFrames.last?.finish(retainChanges: false);
      rethrow;
    } finally {
      _executionDepth--;
      _subqueries.removeLast();
      _targetAliases.removeLast();
      _conflictPolicies.removeLast();
      _counterFrames.removeLast();
    }
  }

  Future<MutationImage> _execute(String sql, List<Object?> parameters,
      {bool foreignKeys = false,
      bool inTransaction = false,
      bool compileOnly = false,
      bool deferTriggerFunctions = false,
      bool? recursiveTriggers}) async {
    if (recursiveTriggers != null) _recursiveTriggers = recursiveTriggers;
    sql = SqlParser.canonicalSchemaCreation(sql);
    if (!compileOnly && _executionDepth == 1) {
      final bulk = _tryBulkIncrement(sql, parameters, foreignKeys: foreignKeys);
      if (bulk != null) return bulk;
    }
    if (!compileOnly) _flushColumnAddends();
    if (!compileOnly && _executionDepth == 1) {
      final inserted =
          _tryDirectInsert(sql, parameters, foreignKeys: foreignKeys);
      if (inserted != null) return inserted;
    }
    final p = SqlParser(sql,
        deferFunctionResolution: deferTriggerFunctions,
        deferFunctionValidation: deferTriggerFunctions);
    final leadingCtes = <String, (List<String>, SelectStatement)>{};
    final cteMaterialization = <String, bool>{};
    if (p.take('WITH')) {
      p.take('RECURSIVE');
      do {
        final key = asciiLower(p.identifier());
        if (leadingCtes.containsKey(key)) {
          throw const SqlException('Duplicate CTE');
        }
        final columns = <String>[];
        if (p.take('(')) {
          do {
            columns.add(p.identifier());
          } while (p.take(','));
          p.require(')');
        }
        p.require('AS');
        if (p.take('NOT')) {
          p.require('MATERIALIZED');
          cteMaterialization[key] = false;
        } else {
          if (p.take('MATERIALIZED')) cteMaterialization[key] = true;
        }
        p.require('(');
        final savedResolution = p.deferFunctionResolution;
        late SelectStatement query;
        p.deferFunctionResolution = true;
        try {
          query = p.select(nested: true);
        } finally {
          p.deferFunctionResolution = savedResolution;
        }
        p.require(')');
        leadingCtes[key] = (columns, query);
      } while (p.take(','));
      if (!['INSERT', 'REPLACE', 'UPDATE', 'DELETE']
          .contains(p.current.keyword)) {
        throw const SqlException('WITH requires a mutation statement');
      }
    }
    final ctePrefix =
        leadingCtes.isEmpty ? '' : sql.substring(0, p.current.offset);
    if (p.take('ANALYZE')) {
      return _maintenance(p, parameters, analyze: true);
    }
    if (p.take('REINDEX')) {
      return _maintenance(p, parameters, analyze: false);
    }
    if (p.take('VACUUM')) {
      return _vacuum(p, parameters, inTransaction: inTransaction);
    }
    if (p.take('CREATE')) {
      if (p.take('VIRTUAL')) {
        return _createVirtualTable(sql, parameters);
      }
      final unique = p.take('UNIQUE');
      if (p.take('TRIGGER')) {
        if (unique || parameters.isNotEmpty) {
          throw const SqlException('Invalid trigger definition');
        }
        final trigger =
            TriggerDefinition.parse(sql, deferFunctionValidation: true);
        final exists = other.any((o) =>
            o.type == 'trigger' &&
            asciiLower(o.name) == asciiLower(trigger.name));
        if (exists) {
          if (p.take('IF')) return MutationImage(original, 0, null);
          throw const SqlException('Trigger exists');
        }
        final table = await _target(trigger.table);
        if (table == null ||
            asciiLower(table.schema.name).startsWith('sqlite_') ||
            (trigger.timing == 'INSTEAD OF') != table.view ||
            asciiLower(trigger.name).startsWith('sqlite_')) {
          throw const SqlException('Trigger target unsupported');
        }
        final values = <String, Object?>{};
        for (final prefix in [
          if (trigger.event != 'INSERT') 'old',
          if (trigger.event != 'DELETE') 'new'
        ]) {
          for (final col in [
            ...table.schema.columns.map((c) => asciiLower(c.name)),
            if (!table.schema.withoutRowid) ...['rowid', '_rowid_', 'oid']
          ]) {
            values['$prefix.$col'] = null;
          }
        }
        trigger.when?.validate(values.keys.toSet());
        if (trigger.when != null &&
            (trigger.when!.containsAggregate || trigger.when!.containsWindow)) {
          throw const SqlException('Aggregate/window in trigger WHEN');
        }
        for (final statement in trigger.statements) {
          final body = SqlParser(statement);
          if (body.tokens.any((t) => t.keyword == 'RETURNING')) {
            throw const SqlException('RETURNING prohibited in trigger bodies');
          }
          if (['SELECT', 'WITH', 'VALUES'].contains(body.current.keyword)) {
            final select =
                SqlParser(statement, deferFunctionResolution: true).select();
            if (select.parameterCount != 0) {
              throw const SqlException(
                  'Parameters prohibited in trigger SELECT');
            }
          } else {
            if (!['INSERT', 'REPLACE', 'UPDATE', 'DELETE']
                .contains(body.current.keyword)) {
              throw const SqlException('Invalid trigger statement');
            }
            final bound = _bindTrigger(statement, values);
            await execute(bound.$1, bound.$2,
                compileOnly: true, deferTriggerFunctions: true);
          }
        }
        other.add(ImageObject('trigger', trigger.name, table.schema.name, sql));
        schemaChanged = true;
        return MutationImage(serialize(), 0, null);
      }
      if (p.take('VIEW')) {
        if (unique) throw const SqlException('Invalid UNIQUE VIEW');
        var ifNotExists = false;
        if (p.take('IF')) {
          p.require('NOT');
          p.require('EXISTS');
          ifNotExists = true;
        }
        final name = p.identifier();
        final key = asciiLower(name);
        if (key.startsWith('sqlite_')) {
          throw const SqlException('Reserved object name');
        }
        if (_tables.containsKey(key) ||
            _indexes.any((i) => asciiLower(i.name) == key) ||
            other.any((o) => o.type == 'view' && asciiLower(o.name) == key)) {
          if (ifNotExists) return MutationImage(original, 0, null);
          throw const SqlException('Object exists');
        }
        if (p.take('(')) {
          do {
            p.identifier();
          } while (p.take(','));
          p.require(')');
        }
        p.require('AS');
        final definition = SqlParser(sql.substring(p.current.offset),
                deferFunctionResolution: true)
            .select();
        if (definition.parameterCount != 0 || parameters.isNotEmpty) {
          throw const SqlException('Parameters prohibited in view');
        }
        other.add(ImageObject('view', name, name, sql));
        schemaChanged = true;
        return MutationImage(serialize(), 0, null);
      }
      if (p.take('TABLE')) {
        if (unique) throw const SqlException('Unexpected UNIQUE TABLE');
        var ifNotExists = false;
        if (p.take('IF')) {
          p.require('NOT');
          p.require('EXISTS');
          ifNotExists = true;
        }
        final name = p.identifier();
        final key = asciiLower(name);
        if (_tables.containsKey(key) ||
            _indexes.any((i) => asciiLower(i.name) == key) ||
            other.any((o) => o.type == 'view' && asciiLower(o.name) == key)) {
          if (ifNotExists) return MutationImage(original, 0, null);
          throw const SqlException('Object already exists');
        }
        if (key.startsWith('sqlite_')) {
          throw const SqlException('Reserved object name');
        }
        if (p.take('AS')) {
          final query = sql.substring(p.current.offset);
          final storage = MemoryStorageBackend();
          await storage.write(0, serialize());
          final reader = await SqliteDatabase.openReadOnly(storage,
              functions: SqlFunctionRegistry.current);
          late QueryResult result;
          try {
            result = await reader.query(query, parameters);
          } finally {
            await reader.close();
          }
          final names = relationColumnNames(result.columns);
          String quote(String value) => '"${value.replaceAll('"', '""')}"';
          String type(int i) {
            final declared = result.columnDeclaredTypes[i].toUpperCase();
            final affinity = declared.isEmpty
                ? result.columnAffinities[i]
                : affinityFor(declared);
            if (affinity == 'text') return 'TEXT';
            if (affinity == 'numeric') {
              if (declared.contains('INT')) return 'INT';
              if (['REAL', 'FLOA', 'DOUB'].any(declared.contains)) {
                return 'REAL';
              }
              return 'NUM';
            }
            return '';
          }

          final definition = 'CREATE TABLE ${quote(name)}(${[
            for (var i = 0; i < names.length; i++)
              '${quote(names[i])} ${type(i)}'.trim()
          ].join(',')})';
          final schema = DatabaseCatalog.parseTable(definition, 0);
          final table = _Table(schema, definition, []);
          for (var i = 0; i < result.rows.length; i++) {
            table.rows.add(_physical(
                table,
                {
                  for (var c = 0; c < names.length; c++)
                    asciiLower(names[c]): result.rows[i][c]
                },
                BigInt.from(i + 1)));
          }
          _tables[key] = table;
          schemaChanged = true;
          return MutationImage(
              serialize(
                  foreignKeys: foreignKeys, includeDeferred: !inTransaction),
              0,
              null);
        }
        final table = DatabaseCatalog.parseTable(sql, 0);
        _tables[key] = _Table(table, sql, []);
        if (table.columns.any((col) => col.autoIncrement) &&
            !_tables.containsKey('sqlite_sequence')) {
          const source = 'CREATE TABLE sqlite_sequence(name,seq)';
          _tables['sqlite_sequence'] =
              _Table(DatabaseCatalog.parseTable(source, 0), source, []);
        }
        final keys = _implicitKeys(table);
        for (var i = 0; i < keys.length; i++) {
          if (table.withoutRowid && table.autoIndexPrimary[i]) {
            continue;
          }
          _indexes.add(_Index(
              'sqlite_autoindex_${table.name}_${i + 1}',
              table.name,
              keys[i],
              table.autoIndexDescending[i],
              table.autoIndexCollations[i],
              true,
              null));
        }
      } else if (p.take('INDEX')) {
        var ifNotExists = false;
        if (p.take('IF')) {
          p.require('NOT');
          p.require('EXISTS');
          ifNotExists = true;
        }
        final name = p.identifier();
        if (_indexes.any((i) => asciiLower(i.name) == asciiLower(name))) {
          if (ifNotExists) return MutationImage(original, 0, null);
          throw const SqlException('Index exists');
        }
        if (_tables.containsKey(asciiLower(name)) ||
            other.any((o) =>
                o.type == 'view' && asciiLower(o.name) == asciiLower(name)) ||
            asciiLower(name).startsWith('sqlite_')) {
          throw const SqlException('Invalid index name');
        }
        _indexes.add(_parseIndex(sql));
      } else {
        throw const SqlException('Unsupported CREATE statement');
      }
      if (parameters.isNotEmpty) {
        throw const SqlException(
            'Bindings are not allowed in schema statements');
      }
      schemaChanged = true;
      return MutationImage(
          serialize(
              foreignKeys: foreignKeys && _executionDepth == 1,
              includeDeferred: !inTransaction),
          0,
          null);
    }
    if (p.take('ALTER')) {
      p.require('TABLE');
      final name = p.qualifiedIdentifier();
      final key = asciiLower(name);
      final table = _tables[key];
      if (table == null) throw const SqlException('No such table');
      if (p.current.keyword == 'DROP' ||
          p.current.keyword == 'RENAME' &&
              p.tokens[p.position + 1].keyword != 'TO') {
        if (parameters.isNotEmpty || key.startsWith('sqlite_')) {
          throw const SqlException('Invalid column alteration');
        }
        final drop = p.take('DROP');
        if (!drop) p.require('RENAME');
        p.take('COLUMN');
        final old = p.identifier();
        final column = _column(table.schema, old);
        final oldKey = asciiLower(column.name);
        final renamed = drop ? null : (p..require('TO')).identifier();
        final quotedRename = !drop && p.tokens[p.position - 1].quoted;
        p.finish();
        final dependencyEdits = <ImageObject, Map<int, String>>{};
        if (!drop) {
          final views = {
            for (final object in other.where((o) => o.type == 'view'))
              asciiLower(object.name): object.sql!
          };
          for (final object in other.where((o) => o.sql != null)) {
            dependencyEdits[object] = renamedColumnReferences(
                object.sql!,
                object.type,
                object.tableName,
                name,
                column.name,
                renamed!,
                _schemaColumns,
                views);
          }
        }
        if (!drop) {
          if (table.schema.columns.any((c) =>
              c != column && asciiLower(c.name) == asciiLower(renamed!))) {
            throw const SqlException('Column exists');
          }
          final changed = _renameColumnSql(table, column.name, renamed!);
          _tables[key] = _Table(
              DatabaseCatalog.parseTable(changed, 0), changed, table.rows);
          for (final entry in _tables.entries.toList()) {
            if (entry.key == key) continue;
            final replacements = _referenceColumnReplacements(
                entry.value.sql, name, column.name, renamed);
            if (replacements.isEmpty) continue;
            final updated = _rewriteIdentifiers(entry.value.sql, replacements);
            _tables[entry.key] = _Table(DatabaseCatalog.parseTable(updated, 0),
                updated, entry.value.rows);
          }
          for (var i = 0; i < _indexes.length; i++) {
            final index = _indexes[i];
            if (asciiLower(index.table) != key) continue;
            var updated = index.sql;
            if (updated != null) {
              final tokens = SqlTokenizer.tokenize(updated);
              final on = tokens.indexWhere((t) => t.keyword == 'ON');
              final replacements = <int, String>{};
              if (index.referencedColumns.contains(oldKey)) {
                for (var j = on + 2; j < tokens.length; j++) {
                  if (tokens[j].kind != SqlTokenKind.identifier ||
                      asciiLower(tokens[j].text) != oldKey) {
                    continue;
                  }
                  if (j + 1 < tokens.length &&
                          tokens[j + 1].kind == SqlTokenKind.symbol &&
                          tokens[j + 1].text == '(' ||
                      ['COLLATE', 'AS'].contains(tokens[j - 1].keyword)) {
                    continue;
                  }
                  replacements[tokens[j].offset] = renamed;
                }
              }
              updated = _rewriteIdentifiers(updated, replacements);
            }
            _indexes[i] = updated != null
                ? _parseIndex(updated)
                : _Index(
                    index.name,
                    index.table,
                    index.columns
                        .map((c) => asciiLower(c) == oldKey ? renamed : c)
                        .toList(),
                    index.descending,
                    index.collations,
                    index.unique,
                    null);
          }
        } else {
          if (table.schema.columns.length == 1 ||
              column.primaryKey != 0 ||
              column.unique ||
              table.schema.autoIndexKeys
                  .any((cols) => cols.any((c) => asciiLower(c) == oldKey)) ||
              _indexes.any((i) =>
                  asciiLower(i.table) == key &&
                  i.referencedColumns.contains(oldKey))) {
            throw const SqlException('Cannot drop key/index column');
          }
          for (final check in [
            ...table.schema.columns
                .where((c) => c != column && c.generatedExpression != null)
                .map((c) => c.generatedExpression!),
            ...table.schema.checks,
            ...table.schema.columns
                .where((c) => c != column)
                .expand((c) => c.checks)
          ]) {
            if (check.unaggregatedColumns
                .any((c) => c.split('.').last == oldKey)) {
              throw const SqlException('Column is used by CHECK');
            }
          }
          for (final child in _tables.values) {
            for (final fk in child.schema.foreignKeys) {
              if (identical(child, table) &&
                      fk.columns.any((c) => asciiLower(c) == oldKey) ||
                  asciiLower(fk.table) == key &&
                      fk.targetColumns.any((c) => asciiLower(c) == oldKey)) {
                throw const SqlException('Column is used by foreign key');
              }
            }
          }
          final parts = _tableParts(table.sql);
          final tokens = parts.$1;
          final remaining = parts.$4
              .where((part) => asciiLower(tokens[part.$1].text) != oldKey)
              .toList();
          if (remaining.length != parts.$4.length - 1) {
            throw const SqlException('Ambiguous column declaration');
          }
          final changed = table.sql.substring(0, tokens[parts.$2].offset + 1) +
              remaining
                  .map((part) => table.sql
                      .substring(tokens[part.$1].offset, tokens[part.$2].offset)
                      .trim())
                  .join(', ') +
              table.sql.substring(tokens[parts.$3].offset);
          final definition = DatabaseCatalog.parseTable(changed, 0);
          final ordinal = table.schema.columns.indexOf(column);
          _tables[key] = _Table(definition, changed, [
            for (final row in table.rows)
              TableRow(row.rowId, [
                for (var i = 0; i < row.values.length; i++)
                  if (i != ordinal) row.values[i]
              ])
          ]);
        }
        final proposed = [
          for (final object in other)
            dependencyEdits[object]?.isNotEmpty == true
                ? ImageObject(
                    object.type,
                    object.name,
                    object.tableName,
                    _rewriteIdentifiers(object.sql!, dependencyEdits[object]!,
                        quote: quotedRename))
                : object
        ];
        validateColumnDependencies(_schemaColumns, _dependentSchema(proposed));
        other
          ..clear()
          ..addAll(proposed);
        schemaChanged = true;
        return MutationImage(
            serialize(
                foreignKeys: foreignKeys, includeDeferred: !inTransaction),
            0,
            null);
      }
      if (p.take('RENAME')) {
        p.require('TO');
        final renamed = p.identifier();
        p.finish();
        if (parameters.isNotEmpty ||
            key.startsWith('sqlite_') ||
            asciiLower(renamed).startsWith('sqlite_')) {
          throw const SqlException('Invalid rename');
        }
        final renamedKey = asciiLower(renamed);
        if (_tables.containsKey(renamedKey) ||
            _indexes.any((i) => asciiLower(i.name) == renamedKey) ||
            other.any(
                (o) => o.type == 'view' && asciiLower(o.name) == renamedKey)) {
          throw const SqlException('Rename target exists');
        }
        final dependentEdits = {
          for (final object in other.where((o) => o.sql != null))
            object:
                renamedTableReferences(object.sql!, object.type, name, renamed)
        };
        final declaration = SqlParser(table.sql);
        declaration.require('CREATE');
        declaration.require('TABLE');
        if (declaration.take('IF')) {
          declaration.require('NOT');
          declaration.require('EXISTS');
        }
        final token = declaration.current;
        final changed = _renameReferences(
            _rewriteIdentifiers(table.sql, {token.offset: renamed}),
            name,
            renamed);
        _tables.remove(key);
        _tables[renamedKey] =
            _Table(DatabaseCatalog.parseTable(changed, 0), changed, table.rows);
        for (final entry in _tables.entries.toList()) {
          if (entry.key == renamedKey) continue;
          final updated = _renameReferences(entry.value.sql, name, renamed);
          if (updated != entry.value.sql) {
            _tables[entry.key] = _Table(DatabaseCatalog.parseTable(updated, 0),
                updated, entry.value.rows);
          }
        }
        for (var i = 0; i < _indexes.length; i++) {
          final index = _indexes[i];
          if (asciiLower(index.table) != key) continue;
          var updated = index.sql;
          if (updated != null) {
            final parser = SqlParser(updated);
            parser.require('CREATE');
            parser.take('UNIQUE');
            parser.require('INDEX');
            if (parser.take('IF')) {
              parser.require('NOT');
              parser.require('EXISTS');
            }
            parser.identifier();
            parser.require('ON');
            updated =
                _rewriteIdentifiers(updated, {parser.current.offset: renamed});
          }
          final indexName = index.sql == null
              ? 'sqlite_autoindex_${renamed}_${index.name.split('_').last}'
              : index.name;
          _indexes[i] = _Index(indexName, renamed, index.columns,
              index.descending, index.collations, index.unique, updated,
              definition: updated == null
                  ? null
                  : IndexDefinition.parse(
                      updated, _tables[renamedKey]!.schema));
        }
        for (var i = 0; i < other.length; i++) {
          final object = other[i];
          final edits = dependentEdits[object];
          if (edits == null || edits.isEmpty) continue;
          other[i] = ImageObject(
              object.type,
              object.name,
              object.type == 'trigger' && asciiLower(object.tableName) == key
                  ? renamed
                  : object.tableName,
              _rewriteIdentifiers(object.sql!, edits));
        }
        final sequence = _sequences.remove(key);
        if (sequence != null) _sequences[renamedKey] = sequence;
        schemaChanged = true;
        return MutationImage(
            serialize(
                foreignKeys: foreignKeys, includeDeferred: !inTransaction),
            0,
            null);
      }
      p.require('ADD');
      p.take('COLUMN');
      final declaration = sql
          .substring(p.current.offset)
          .trim()
          .replaceFirst(RegExp(r';\s*$'), '');
      final parts = _tableParts(table.sql);
      final constraint = parts.$4
          .where((part) => const {
                'CONSTRAINT',
                'PRIMARY',
                'UNIQUE',
                'CHECK',
                'FOREIGN'
              }.contains(parts.$1[part.$1].keyword))
          .firstOrNull;
      // Column declarations must precede table constraints. Keep the original
      // delimiter and comments after the inserted declaration, as SQLite does.
      final end =
          parts.$1[constraint == null ? parts.$3 : constraint.$1 - 1].offset;
      final changed =
          '${table.sql.substring(0, end)}, $declaration${table.sql.substring(end)}';
      final definition = DatabaseCatalog.parseTable(changed, 0);
      if (definition.columns.length != table.schema.columns.length + 1) {
        throw const SqlException('Invalid added column');
      }
      final column = definition.columns.last;
      if (column.generatedStored) {
        throw const SqlException('Cannot ADD a STORED column');
      }
      if (column.primaryKey != 0 || column.unique) {
        throw const SqlException('Cannot add a PRIMARY KEY or UNIQUE column');
      }
      if (column.defaultSql != null) {
        final value = SqlParser(column.defaultSql!).expression();
        if (!isLiteralConstant(value)) {
          throw const SqlException('ALTER default must be constant');
        }
      }
      if (foreignKeys &&
          definition.foreignKeys.length > table.schema.foreignKeys.length &&
          column.defaultValue != null) {
        throw const SqlException(
            'Foreign key added column requires NULL default');
      }
      _tables[key] = _Table(definition, changed, [
        for (final row in table.rows)
          TableRow(
              row.rowId, [...row.values, _stored(column.defaultValue, column)])
      ]);
      schemaChanged = true;
      if (parameters.isNotEmpty) {
        throw const SqlException('Schema bindings unsupported');
      }
      return MutationImage(
          serialize(
              foreignKeys: foreignKeys && _executionDepth == 1,
              includeDeferred: !inTransaction),
          0,
          null);
    }
    if (p.take('DROP')) {
      final table = p.take('TABLE');
      final view = !table && p.take('VIEW');
      final trigger = !table && !view && p.take('TRIGGER');
      if (!table && !view && !trigger) p.require('INDEX');
      var ifExists = false;
      if (p.take('IF')) {
        p.require('EXISTS');
        ifExists = true;
      }
      final name = p.qualifiedIdentifier();
      p.finish();
      if (parameters.isNotEmpty) {
        throw const SqlException('Schema bindings unsupported');
      }
      if (view || trigger) {
        final matching = other
            .where((o) =>
                o.type == (trigger ? 'trigger' : 'view') &&
                asciiLower(o.name) == asciiLower(name))
            .toList();
        if (matching.isEmpty) {
          if (ifExists) return MutationImage(original, 0, null);
          throw const SqlException('No such view');
        }
        other.removeWhere(matching.contains);
        schemaChanged = true;
        return MutationImage(serialize(), 0, null);
      }
      if (table) {
        final virtual = other
            .where((object) =>
                object.virtualTable &&
                asciiLower(object.name) == asciiLower(name))
            .toList();
        if (virtual.isNotEmpty) {
          final declaration =
              VirtualTableDeclaration.parse(virtual.single.sql!);
          final module = VirtualTableRegistry.current?.find(declaration.module);
          if (module == null) {
            throw SqlException('No such module: ${declaration.module}');
          }
          invokeVirtualTableCallback(
              'xDestroy', () => module.xDestroy(declaration.name));
          _dropSearchShadows(module, declaration);
          other.removeWhere(virtual.contains);
          schemaChanged = true;
          return MutationImage(serialize(), 0, null);
        }
        if (!_tables.containsKey(asciiLower(name))) {
          if (ifExists) return MutationImage(original, 0, null);
          throw const SqlException('No such table');
        }
        final dropping = _tables[asciiLower(name)]!;
        if (foreignKeys) {
          final implicitDelete = _tables.values.any((child) =>
              child.schema.foreignKeys.any((key) =>
                  asciiLower(key.table) == asciiLower(dropping.schema.name)));
          if (implicitDelete) {
            _beginCounters();
          }
          for (final row in dropping.rows.toList()) {
            dropping.rows.remove(row);
            await _referentialActions(dropping, row, null, 0,
                inTransaction: inTransaction);
            if (implicitDelete) {
              _changed();
            }
          }
        }
        _tables.remove(asciiLower(name));
        _removeStatistics(table: dropping.schema.name);
        _sequences.remove(asciiLower(name));
        _indexes.removeWhere((i) => asciiLower(i.table) == asciiLower(name));
        other.removeWhere((o) => asciiLower(o.tableName) == asciiLower(name));
      } else {
        final index = _indexes
            .where((i) => asciiLower(i.name) == asciiLower(name))
            .firstOrNull;
        if (index == null) {
          if (ifExists) return MutationImage(original, 0, null);
          throw const SqlException('No such index');
        }
        if (index.sql == null) {
          throw const SqlException('Cannot drop constraint index');
        }
        _indexes.remove(index);
        _removeStatistics(index: index.name);
      }
      schemaChanged = true;
      return MutationImage(
          serialize(
              foreignKeys: foreignKeys && _executionDepth == 1,
              includeDeferred: !inTransaction),
          0,
          null);
    }
    final replace = p.take('REPLACE');
    final insert = replace || p.take('INSERT');
    final update = !insert && p.take('UPDATE');
    if (!insert && !update) p.require('DELETE');
    var policy = replace ? 'REPLACE' : 'DEFAULT';
    final explicitPolicy = replace || (insert || update) && p.take('OR');
    if (explicitPolicy && !replace) {
      policy = p.identifier().toUpperCase();
      if (!['ABORT', 'IGNORE', 'REPLACE', 'FAIL', 'ROLLBACK']
          .contains(policy)) {
        throw const SqlException('Unsupported conflict policy');
      }
    }
    _conflictPolicies[_conflictPolicies.length - 1] ??=
        explicitPolicy ? policy : null;
    policy = _conflictPolicies.last ?? policy;
    if (insert) p.require('INTO');
    if (!insert && !update) p.require('FROM');
    final name = p.qualifiedIdentifier(
        allowQualified: !compileOnly && _triggerContexts.isEmpty);
    final alias = p.take('AS') ? p.identifier() : name;
    String? requiredIndex;
    if (!insert) {
      if (p.take('INDEXED')) {
        if (compileOnly || _triggerContexts.isNotEmpty) {
          throw const SqlException('INDEXED BY prohibited in trigger body');
        }
        p.require('BY');
        requiredIndex = p.identifier();
      } else if (p.take('NOT')) {
        if (compileOnly || _triggerContexts.isNotEmpty) {
          throw const SqlException('NOT INDEXED prohibited in trigger body');
        }
        p.require('INDEXED');
      }
    }
    if (_searchTarget(name) != null) {
      return _searchWrite(sql, parameters, compileOnly: compileOnly);
    }
    _targetAliases.last[asciiLower(name)] = asciiLower(alias);
    final table = await _target(name);
    if (table == null) throw SqlException('No such table: $name');
    if (table.view &&
        !other
            .where((o) =>
                o.type == 'trigger' &&
                asciiLower(o.tableName) == asciiLower(name))
            .map((o) => TriggerDefinition.parse(o.sql!))
            .any((t) =>
                t.timing == 'INSTEAD OF' &&
                t.event ==
                    (insert
                        ? 'INSERT'
                        : update
                            ? 'UPDATE'
                            : 'DELETE'))) {
      throw SqlException('Cannot modify view: $name');
    }
    final schema = table.schema;
    final columnNames = schema.columns.map((c) => asciiLower(c.name)).toList();
    final writable = {
      ...schema.columns
          .where((c) => c.generatedExpression == null)
          .map((c) => asciiLower(c.name)),
      if (!schema.withoutRowid)
        ...['rowid', '_rowid_', 'oid']
            .where((name) => !columnNames.contains(name)),
    };
    final valid = {
      ...columnNames,
      ...(table.view ? <String>{} : writable),
      for (final col in {...columnNames, if (!table.view) ...writable}) ...{
        '${asciiLower(alias)}.$col',
        'main.${asciiLower(alias)}.$col'
      },
      ...?_triggerContexts.lastOrNull?.row.keys
    };
    List<String> assignmentTargets() {
      final tuple = p.take('('), fields = <String>[];
      do {
        final field = asciiLower(p.identifier());
        if (!writable.contains(field)) {
          throw const SqlException('Unknown assignment column');
        }
        fields.add(field);
      } while (tuple && p.take(','));
      if (tuple) p.require(')');
      return fields;
    }

    void validateRequiredIndex(Expr? predicate) {
      if (requiredIndex == null) return;
      final index = _indexes
          .where((index) =>
              asciiLower(index.name) == asciiLower(requiredIndex!) &&
              asciiLower(index.table) == asciiLower(name))
          .firstOrNull;
      if (index == null) {
        final primary = schema.autoIndexPrimary.indexOf(true) + 1;
        if (!(schema.withoutRowid &&
            asciiLower(requiredIndex) ==
                asciiLower('sqlite_autoindex_${schema.name}_$primary'))) {
          throw SqlException('No such index: $requiredIndex');
        }
      } else if (!impliesIndexPredicate(predicate, index.definition?.predicate,
          columnKey: (column) => indexColumnKey(column, alias))) {
        throw const SqlException('No query solution for required index');
      }
    }

    final input = <String>[];
    final inserts = <List<Expr>>[];
    var insertSelect = false;
    (String, SelectStatement)? insertQuery;
    final assignments = <String, Expr>{};
    List<QuerySource>? fromSources;
    Expr? where;
    if (insert) {
      if (p.take('(')) {
        do {
          input.add(asciiLower(p.identifier()));
        } while (p.take(','));
        p.require(')');
      } else {
        input.addAll(schema.columns
            .where((c) => c.generatedExpression == null)
            .map((c) => asciiLower(c.name)));
      }
      if (input.toSet().length != input.length ||
          input.any((c) => !writable.contains(c))) {
        throw const SqlException('Invalid INSERT columns');
      }
      if (p.take('DEFAULT')) {
        p.require('VALUES');
        input.clear();
        inserts.add([]);
      } else if (['SELECT', 'WITH'].contains(p.current.keyword)) {
        insertSelect = true;
        var tail = p.tokens.length - 1;
        var depth = 0;
        for (var i = p.position; i < p.tokens.length; i++) {
          final token = p.tokens[i];
          if (token.text == '(') depth++;
          if (token.text == ')') depth--;
          if (depth == 0 &&
              (token.keyword == 'RETURNING' ||
                  token.keyword == 'ON' &&
                      i + 1 < p.tokens.length &&
                      p.tokens[i + 1].keyword == 'CONFLICT')) {
            tail = i;
            break;
          }
        }
        final query =
            '$ctePrefix${sql.substring(p.current.offset, p.tokens[tail].offset)}';
        final queryParser = SqlParser(query,
            deferFunctionResolution: deferTriggerFunctions,
            deferFunctionValidation: deferTriggerFunctions);
        final statement = queryParser.select();
        p.parameterNames.addAll(queryParser.parameterNames);
        insertQuery = (query, statement);
        p.position = tail;
        p.parameterCount = statement.parameterCount;
      } else {
        p.require('VALUES');
        do {
          p.require('(');
          final row = <Expr>[];
          do {
            final expr = p.expression();
            expr.validate(_triggerContexts.lastOrNull?.row.keys.toSet() ?? {});
            if (expr.containsAggregate || expr.containsWindow) {
              throw const SqlException('Aggregate in INSERT');
            }
            row.add(expr);
          } while (p.take(','));
          p.require(')');
          if (row.length != input.length) {
            throw const SqlException('INSERT width mismatch');
          }
          inserts.add(row);
        } while (p.take(','));
      }
    } else {
      if (update) {
        p.require('SET');
        do {
          final targets = assignmentTargets();
          p.require('=');
          final expr = p.expression();
          if (expr.containsAggregate || expr.containsWindow) {
            throw const SqlException('Aggregate in UPDATE');
          }
          final fields = assignmentFields(expr, targets.length);
          for (var i = 0; i < targets.length; i++) {
            assignments[targets[i]] = fields[i];
          }
        } while (p.take(','));
        if (p.take('FROM')) {
          var tail = p.tokens.length - 1;
          var depth = 0;
          for (var i = p.position; i < p.tokens.length; i++) {
            final token = p.tokens[i];
            if (token.text == '(') depth++;
            if (token.text == ')') depth--;
            if (depth == 0 && ['WHERE', 'RETURNING'].contains(token.keyword)) {
              tail = i;
              break;
            }
          }
          final parser = SqlParser('SELECT 1 FROM '
              '${sql.substring(p.current.offset, p.tokens[tail].offset)}')
            ..parameterCount = p.parameterCount
            ..parameterNames.addAll(p.parameterNames);
          fromSources = parser.select().sources;
          p.parameterCount = parser.parameterCount;
          p.parameterNames.addAll(parser.parameterNames);
          p.position = tail;
        }
      }
      if (p.take('WHERE')) {
        where = p.expression();
        if (where.containsAggregate || where.containsWindow) {
          throw const SqlException('Aggregate in WHERE');
        }
      }
      if (fromSources == null) {
        for (final expression in assignments.values) {
          expression.validate(valid);
        }
        where?.validate(valid);
      }
    }
    final upserts = <_Upsert>[];
    if (insert) {
      while (p.take('ON')) {
        p.require('CONFLICT');
        List<Expr>? target;
        _Index? targetIndex;
        if (p.take('(')) {
          target = <Expr>[];
          final targetCollations = <String?>[];
          do {
            final expression = p.expression();
            expression.validate(columnNames.toSet());
            if (expression.containsAggregate || expression.containsWindow) {
              throw const SqlException('Invalid conflict target');
            }
            target.add(expression);
            targetCollations.add(expression
                .explicitCollation(EvalContext({}, {}, [], encoding)));
            if (!p.take('DESC')) p.take('ASC');
          } while (p.take(','));
          p.require(')');
          final targetWhere = p.take('WHERE') ? p.expression() : null;
          targetWhere?.validate(columnNames.toSet());
          if (targetWhere != null &&
              (targetWhere.containsAggregate || targetWhere.containsWindow)) {
            throw const SqlException('Invalid conflict target WHERE');
          }
          bool matches(_Index index) {
            if (!index.unique ||
                asciiLower(index.table) != asciiLower(name) ||
                index.columns.length != target!.length ||
                index.definition?.predicate != null &&
                    (targetWhere == null ||
                        !sameExpression(
                            targetWhere, index.definition!.predicate!))) {
              return false;
            }
            final used = <int>{};
            for (var i = 0; i < target.length; i++) {
              var matched = false;
              for (var j = 0; j < index.columns.length; j++) {
                final expression = index.definition?.terms[j].expression ??
                    ColumnExpr(index.columns[j]);
                if (!used.contains(j) &&
                    sameExpression(
                        indexOperand(expression), indexOperand(target[i])) &&
                    (targetCollations[i] == null ||
                        targetCollations[i] == index.collations[j])) {
                  used.add(j);
                  matched = true;
                  break;
                }
              }
              if (!matched) return false;
            }
            return true;
          }

          final candidates = _indexes.toList();
          if (schema.withoutRowid) {
            final pk = schema.columns.where((c) => c.primaryKey != 0).toList()
              ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
            candidates.add(_Index(
                '@pk',
                name,
                pk.map((c) => c.name).toList(),
                schema.primaryKeyDescending,
                schema.primaryKeyCollations,
                true,
                null));
          }
          targetIndex = candidates.where(matches).firstOrNull;
          final single =
              target.length == 1 ? indexOperand(target.single) : null;
          final rowid = !schema.withoutRowid &&
              single is ColumnExpr &&
              (single.key == asciiLower(schema.rowidAlias ?? '') ||
                  ['rowid', '_rowid_', 'oid'].contains(single.key) &&
                      !columnNames.contains(single.key));
          if (targetIndex == null && !rowid) {
            throw const SqlException('ON CONFLICT target is not unique');
          }
        }
        p.require('DO');
        final nothing = p.take('NOTHING');
        final changes = <String, Expr>{};
        Expr? predicate;
        if (!nothing) {
          p.require('UPDATE');
          p.require('SET');
          final scope = {
            ...valid,
            for (final key in [...columnNames, 'rowid', '_rowid_', 'oid'])
              'excluded.$key'
          };
          do {
            final targets = assignmentTargets();
            p.require('=');
            final expr = p.expression();
            if (expr.containsAggregate || expr.containsWindow) {
              throw const SqlException('Aggregate/window in UPSERT');
            }
            final fields = assignmentFields(expr, targets.length);
            for (var i = 0; i < targets.length; i++) {
              fields[i].validate(scope);
              changes[targets[i]] = fields[i];
            }
          } while (p.take(','));
          if (p.take('WHERE')) {
            predicate = p.expression();
            predicate.validate(scope);
            if (predicate.containsAggregate || predicate.containsWindow) {
              throw const SqlException('Aggregate/window in UPSERT WHERE');
            }
          }
        }
        upserts.add(_Upsert(target, targetIndex, nothing, changes, predicate));
        if (target == null) break;
      }
    }
    if (table.view && upserts.isNotEmpty) {
      throw const SqlException('UPSERT on view unsupported');
    }
    final returning = <SelectItem>[];
    final hasReturning = p.take('RETURNING');
    final returningValid = {
      ...columnNames,
      if (!table.view) ...writable,
      for (final column in {...columnNames, if (!table.view) ...writable})
        '${asciiLower(name)}.$column'
    };
    if (hasReturning) {
      if (_activeTriggers.isNotEmpty) {
        throw const SqlException('RETURNING prohibited in trigger bodies');
      }
      do {
        if (p.take('*')) {
          returning.addAll(schema.columns
              .map((c) => SelectItem(ColumnExpr(c.name), c.name)));
        } else {
          final start = p.current.offset;
          final expression = p.expression();
          var label = sql.substring(start, p.current.offset).trim();
          if (expression is ColumnExpr) {
            final key = expression.key.split('.').last;
            label = schema.columns
                    .where((c) => asciiLower(c.name) == key)
                    .firstOrNull
                    ?.name ??
                key;
          }
          if (p.take('AS')) {
            label = p.identifier();
          } else if (p.current.kind == SqlTokenKind.identifier) {
            label = p.identifier();
          }
          expression.validate(returningValid);
          if (expression.containsAggregate || expression.containsWindow) {
            throw const SqlException('Aggregate/window in RETURNING');
          }
          returning.add(SelectItem(expression, label));
        }
      } while (p.take(','));
    }
    void orderAssignments(Map<String, Expr> fields) {
      final original = {
        for (var i = 0; i < fields.length; i++) fields.keys.elementAt(i): i
      };
      int position(String column) => !schema.withoutRowid &&
              (column == asciiLower(schema.rowidAlias ?? '') ||
                  !columnNames.contains(column) &&
                      ['rowid', '_rowid_', 'oid'].contains(column))
          ? -1
          : columnNames.indexOf(column);
      final entries = fields.entries.toList()
        ..sort((a, b) {
          final difference = position(a.key).compareTo(position(b.key));
          return difference != 0
              ? difference
              : original[a.key]!.compareTo(original[b.key]!);
        });
      fields
        ..clear()
        ..addEntries(entries);
    }

    orderAssignments(assignments);
    for (final clause in upserts) {
      orderAssignments(clause.assignments);
    }
    validateRequiredIndex(where);
    p.finish();
    if (parameters.length != p.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    if (foreignKeys && !table.view) {
      bool mayReplace(Set<String>? changed) {
        bool affects(Iterable<String> columns) =>
            changed == null ||
            columns.any((column) => changed.contains(asciiLower(column)));
        if ((policy == 'REPLACE' ||
                policy == 'DEFAULT' && schema.primaryPolicy == 'REPLACE') &&
            affects([
              ...schema.columns
                  .where((column) => column.primaryKey != 0)
                  .map((column) => column.name),
              if (!schema.withoutRowid) ...['rowid', '_rowid_', 'oid']
            ])) {
          return true;
        }
        return _indexes.any((index) =>
            index.unique &&
            asciiLower(index.table) == asciiLower(name) &&
            (policy == 'REPLACE' ||
                policy == 'DEFAULT' && _indexPolicy(index) == 'REPLACE') &&
            affects(index.referencedColumns));
      }

      final changed = assignments.keys.toSet();
      _prepareForeignKeys(
          table,
          insert
              ? 'INSERT'
              : update
                  ? 'UPDATE'
                  : 'DELETE',
          updated: changed,
          replacing: mayReplace(insert ? null : changed));
      for (final upsert in upserts.where((upsert) => !upsert.nothing)) {
        _prepareForeignKeys(table, 'UPDATE',
            updated: upsert.assignments.keys.toSet());
      }
    }
    if (!deferTriggerFunctions) {
      for (final column in schema.columns) {
        final name = asciiLower(column.name);
        final defaultExpression = column.defaultExpression;
        final replacedNull = column.notNull &&
            (insert || assignments.containsKey(name)) &&
            (policy == 'REPLACE' ||
                policy == 'DEFAULT' && column.notNullPolicy == 'REPLACE');
        if (defaultExpression == null ||
            column.name == schema.rowidAlias ||
            column.generatedExpression != null ||
            !(insert && !input.contains(name) || replacedNull)) {
          continue;
        }
        _resolveExpressionFunctions(defaultExpression);
        if (defaultExpression.containsAggregate ||
            defaultExpression.containsWindow) {
          throw const SqlException('Aggregate/window in schema default');
        }
      }
      await _prepareTriggerPrograms(
          table,
          insert
              ? 'INSERT'
              : update
                  ? 'UPDATE'
                  : 'DELETE',
          assignments.keys.toSet());
      for (final upsert in upserts.where((upsert) => !upsert.nothing)) {
        await _prepareTriggerPrograms(
            table, 'UPDATE', upsert.assignments.keys.toSet());
      }
      if (insertQuery != null) _resolveQueryFunctions(insertQuery.$2);
      for (final expression in [
        ...inserts.expand((row) => row),
        ...assignments.values,
        if (where != null) where,
        for (final clause in upserts) ...[
          ...clause.assignments.values,
          if (clause.where != null) clause.where!
        ],
        ...returning.map((item) => item.expression!)
      ]) {
        _resolveExpressionFunctions(expression);
      }
    }
    if (compileOnly) return MutationImage(original, 0, null);
    _beginCounters();
    final bound = parameters.map(sqlValue).toList();
    final expressions = [
      ...inserts.expand((row) => row),
      ...assignments.values,
      if (where != null) where,
      for (final clause in upserts) ...[
        ...clause.assignments.values,
        if (clause.where != null) clause.where!
      ],
      ...returning.map((item) => item.expression!)
    ];
    Iterable<SelectStatement> queries(Expr expression) sync* {
      if (expression is SubqueryExpr) yield expression.statement;
      if (expression is InSelectExpr) yield expression.statement;
      for (final child in expression.children) {
        yield* queries(child);
      }
    }

    if (leadingCtes.isNotEmpty) {
      for (final expression in expressions) {
        for (final query in queries(expression)) {
          final own = Map.of(query.ctes);
          query.ctes
            ..clear()
            ..addAll(leadingCtes)
            ..addAll(own);
          query.cteMaterialization.addAll(cteMaterialization);
        }
      }
    }

    final cteReferences = <String, int>{};
    final visitedQueries = <SelectStatement>{};
    void countReferences(SelectStatement query) {
      if (!visitedQueries.add(query)) return;
      for (final source in query.leafSources) {
        if (source.table != null) {
          final key = asciiLower(source.table!);
          cteReferences[key] = (cteReferences[key] ?? 0) + 1;
        }
        if (source.query != null) countReferences(source.query!);
      }
      for (final cte in query.ctes.values) {
        countReferences(cte.$2);
      }
      for (final part in query.compounds) {
        countReferences(part.$2);
      }
      for (final expr in [
        ...query.items.map((item) => item.expression),
        query.where,
        ...query.groupBy,
        query.having,
        ...query.order.map((term) => term.expression),
        ...query.leafSources.map((source) => source.on)
      ].whereType<Expr>()) {
        queries(expr).forEach(countReferences);
      }
    }

    for (final expression in expressions) {
      queries(expression).forEach(countReferences);
    }
    final materializedCtes =
        <SelectStatement, (CatalogTable, List<RowValues>)?>{
      for (final query in visitedQueries)
        for (final entry in query.ctes.entries)
          if (query.cteMaterialization[entry.key] == true ||
              query.cteMaterialization[entry.key] != false &&
                  (cteReferences[entry.key] ?? 0) > 1)
            entry.value.$2: null
    };

    bool readsTarget(SelectStatement query) =>
        query.leafSources.any((source) =>
            source.table != null &&
                asciiLower(source.table!) == asciiLower(name) ||
            source.query != null && readsTarget(source.query!)) ||
        query.ctes.values.any((cte) => readsTarget(cte.$2)) ||
        query.compounds.any((part) => readsTarget(part.$2)) ||
        [
          ...query.items.map((item) => item.expression),
          query.where,
          ...query.groupBy,
          query.having,
          ...query.order.map((term) => term.expression),
          ...query.leafSources.map((source) => source.on)
        ].whereType<Expr>().any((expr) => queries(expr).any(readsTarget));

    SqlRows Function(SelectStatement, EvalContext)? snapshotSubquery;
    if (expressions.any((expr) => queries(expr).isNotEmpty)) {
      final storage = MemoryStorageBackend();
      await storage.write(0, serialize());
      final reader = await SqliteDatabase.openReadOnly(storage,
          functions: SqlFunctionRegistry.current);
      try {
        _subqueries[_subqueries.length - 1] =
            await reader.prepareSubqueries(expressions,
                materializedCtes: materializedCtes,
                relations: (names) => {
                      for (final entry in {
                        ..._tables,
                        if (table.view) asciiLower(name): table
                      }.entries)
                        for (final key in [entry.key, 'main.${entry.key}'])
                          if (names.contains(key))
                            key: (
                              entry.value.schema,
                              entry.value.rows
                                  .map((row) => _row(entry.value, row))
                                  .toList()
                            )
                    });
        if (where != null) {
          snapshotSubquery = await reader
              .prepareSubqueries([where], materializedCtes: materializedCtes);
        }
      } finally {
        await reader.close();
      }
    }
    // Multi-row self-reading VALUES are materialized before writes, including
    // callbacks in the other terms. A single VALUES row evaluates directly in
    // declared destination order, including with triggers and RETURNING.
    if (insert &&
        inserts.length > 1 &&
        (hasReturning ||
            other.any((object) =>
                object.type == 'trigger' &&
                asciiLower(object.tableName) == asciiLower(name) &&
                TriggerDefinition.parse(object.sql!).event == 'INSERT') ||
            inserts
                .expand((row) => row)
                .any((expr) => queries(expr).any(readsTarget)))) {
      final context = _constantContext(bound);
      for (var i = 0; i < inserts.length; i++) {
        inserts[i] = inserts[i]
            .map((expression) => Literal(expression.evaluate(context)))
            .toList();
      }
    }
    Stream<List<Expr>> selectedInsertRows() async* {
      final (query, statement) = insertQuery!;
      final storage = MemoryStorageBackend();
      await storage.write(0, serialize());
      final reader = await SqliteDatabase.openReadOnly(storage,
          functions: SqlFunctionRegistry.current);
      try {
        final execution = await reader.prepareInsertSelect(
            query,
            parameters.take(statement.parameterCount).toList(),
            _triggerContexts.lastOrNull);
        if (execution.columns.length != input.length) {
          throw const SqlException('INSERT SELECT width mismatch');
        }
        final materialize = hasReturning ||
            other.any((object) =>
                object.type == 'trigger' &&
                asciiLower(object.tableName) == asciiLower(name) &&
                TriggerDefinition.parse(object.sql!).event == 'INSERT') ||
            reader.queryReadsTable(statement, name);
        final rows = materialize ? execution.rows.toList() : execution.rows;
        for (final row in rows) {
          yield row.map(Literal.new).toList();
        }
      } finally {
        await reader.close();
      }
    }

    BigInt id(Object? value) {
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

    final returnedRows = <List<Object?>>[];
    void emit(TableRow row) {
      if (!hasReturning) return;
      final context = _context(table, row, bound, returning: true);
      returnedRows.add(returning.map((item) {
        final expr = item.expression!;
        final value = expr.evaluate(context);
        if (table.view &&
            expr is ColumnExpr &&
            value is BigInt &&
            schema.columns.any((c) =>
                asciiLower(c.name) == expr.key.split('.').last &&
                ['REAL', 'FLOA', 'DOUB']
                    .any(c.declaredType.toUpperCase().contains) &&
                !c.declaredType.toUpperCase().contains('INT'))) {
          return value.toDouble();
        }
        return value;
      }).toList());
    }

    QueryResult? returned() => hasReturning
        ? QueryResult(
            returning.map((item) => item.label).toList(), returnedRows)
        : null;
    var changes = 0;
    BigInt? last;
    // A WHERE clause that is only "rowid = <integer>" names one row. Scanning
    // and sorting the whole table for that comparison made each single-row
    // update and delete cost grow with the table.
    BigInt? soleRowid;
    var soleExact = false;
    if (!insert &&
        !table.view &&
        !schema.withoutRowid &&
        where != null &&
        fromSources == null &&
        where is BinaryExpr &&
        ['=', '=='].contains(where.op)) {
      final comparison = where;
      ColumnExpr? column;
      Expr? constant;
      if (comparison.left is ColumnExpr && comparison.right is! ColumnExpr) {
        column = comparison.left as ColumnExpr;
        constant = comparison.right;
      } else if (comparison.right is ColumnExpr &&
          comparison.left is! ColumnExpr) {
        column = comparison.right as ColumnExpr;
        constant = comparison.left;
      }
      if (column != null && constant != null) {
        final parts = column.key.split('.');
        final field = parts.last;
        final aliasName = asciiLower(schema.rowidAlias ?? '');
        final namesRowid = field == 'rowid' ||
            field == 'oid' ||
            field == '_rowid_' ||
            (aliasName.isNotEmpty && field == aliasName);
        final qualifierOk = parts.length == 1 ||
            parts.length == 2 &&
                (parts.first == asciiLower(alias) ||
                    parts.first == asciiLower(name)) ||
            parts.length == 3 &&
                parts[0] == 'main' &&
                (parts[1] == asciiLower(alias) || parts[1] == asciiLower(name));
        if (namesRowid && qualifierOk) {
          try {
            constant.validate({});
            var value = constant.evaluate(_constantContext(bound));
            final directInteger = value is BigInt || value is int;
            value =
                value is String || value is Uint8List ? numeric(value) : value;
            if (value is int) value = BigInt.from(value);
            if (value is double &&
                value.isFinite &&
                value == value.truncateToDouble() &&
                value > -(BigInt.one << 63).toDouble() &&
                value < (BigInt.one << 63).toDouble()) {
              value = BigInt.from(value);
            }
            if (value is BigInt &&
                value >= -(BigInt.one << 63) &&
                value < BigInt.one << 63) {
              soleRowid = value;
              soleExact = directInteger;
            }
          } on SqlException {
            soleRowid = null;
          }
        }
      }
    }
    // UPDATE and DELETE walk the pre-image. An insert does not, and sorting
    // every existing row made the next insert slower as the table grew.
    final List<TableRow> originalRows;
    if (insert) {
      originalRows = const [];
    } else if (soleRowid != null) {
      TableRow? found;
      for (final row in table.rows) {
        if (row.rowId == soleRowid) {
          found = row;
          break;
        }
      }
      final matched = found != null &&
          (soleExact ||
              truth(where!.evaluate(_context(table, found, bound)), encoding) ==
                  true);
      if (found != null && !matched || found == null && !soleExact) {
        // The folded integer and the real comparison disagreed, or a coerced
        // constant named a missing row. Walk every row with that comparison.
        soleRowid = null;
        originalRows = table.rows.toList();
      } else {
        originalRows = found == null ? const <TableRow>[] : [found];
      }
    } else {
      originalRows = table.rows.toList();
    }
    if (!insert && !table.view && soleRowid == null) {
      if (schema.withoutRowid) {
        final primary = schema.columns.where((c) => c.primaryKey != 0).toList()
          ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
        final index = _Index(
            '@pk',
            name,
            primary.map((c) => c.name).toList(),
            schema.primaryKeyDescending,
            schema.primaryKeyCollations,
            true,
            null);
        originalRows.sort((a, b) => _compare(index,
            _key(table, a, index.columns), _key(table, b, index.columns)));
      } else {
        originalRows.sort((a, b) => a.rowId.compareTo(b.rowId));
      }
    }
    final singleForeignKeyInsert = foreignKeys &&
        _executionDepth == 1 &&
        insert &&
        !insertSelect &&
        inserts.length == 1 &&
        !hasReturning &&
        upserts.isEmpty &&
        policy != 'REPLACE' &&
        schema.primaryPolicy != 'REPLACE' &&
        !schema.autoIndexPolicies.contains('REPLACE') &&
        !other.any((o) =>
            o.type == 'trigger' &&
            asciiLower(o.tableName) == asciiLower(name) &&
            TriggerDefinition.parse(o.sql!).event == 'INSERT');
    Map<TableRow, List<Object?>>? fromAssignments;
    List<(TableRow, List<Object?>)>? viewFromAssignments;
    if (fromSources != null) {
      const identity = '\u0000sqlite_plus_update_row';
      final query = SelectStatement(
          [
            SelectItem(ColumnExpr('${asciiLower(alias)}.$identity'), identity),
            for (final entry in assignments.entries)
              SelectItem(entry.value, entry.key)
          ],
          null,
          where,
          [],
          null,
          null,
          false,
          p.parameterCount)
        ..sources.addAll(fromSources)
        ..sources.add(QuerySource(
            table: name,
            schema: 'main',
            alias: alias,
            rowIdentity: identity,
            indexedBy: requiredIndex))
        ..ctes.addAll(leadingCtes)
        ..cteMaterialization.addAll(cteMaterialization);
      final storage = MemoryStorageBackend();
      await storage.write(0, serialize());
      final reader = await SqliteDatabase.openReadOnly(storage,
          functions: SqlFunctionRegistry.current);
      try {
        final run =
            await reader.prepareSubqueries([SubqueryExpr(query, exists: true)],
                relations: (names) => {
                      for (final key in [
                        asciiLower(name),
                        'main.${asciiLower(name)}'
                      ])
                        if (names.contains(key))
                          key: (
                            schema,
                            originalRows.map((row) => _row(table, row)).toList()
                          )
                    });
        final values = run(query, _constantContext(bound));
        fromAssignments = {
          for (final row in values.rows)
            originalRows[(row.first as BigInt).toInt() - 1]: row.sublist(1)
        };
        if (table.view) {
          viewFromAssignments = [
            for (final row in values.rows)
              (originalRows[(row.first as BigInt).toInt() - 1], row.sublist(1))
          ];
        }
      } finally {
        await reader.close();
      }
    }
    String canonical(Object? value, String collation) {
      if (value is BigInt) return 'n:$value';
      if (value is double) {
        return value.isFinite && value == value.truncateToDouble()
            ? 'n:${BigInt.from(value)}'
            : 'r:$value';
      }
      if (value is Uint8List) return 'b:${base64Encode(value)}';
      var text = value as String;
      if (collation == 'nocase') text = asciiLower(text);
      if (collation == 'rtrim') text = text.replaceFirst(RegExp(r' +$'), '');
      return 't:$text';
    }

    final uniqueIndexes = _indexes
        .where((i) => i.unique && asciiLower(i.table) == asciiLower(name))
        .toList();
    if (schema.withoutRowid) {
      final pk = schema.columns.where((c) => c.primaryKey != 0).toList()
        ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
      uniqueIndexes.add(_Index(
          '@pk',
          name,
          pk.map((c) => c.name).toList(),
          schema.primaryKeyDescending,
          schema.primaryKeyCollations,
          true,
          null));
    }
    String? keyFor(_Index index, TableRow row) {
      if (!_includes(index, table, row)) return null;
      final key = _indexKey(index, table, row);
      if (key.any((v) => v == null)) return null;
      return jsonEncode([
        for (var i = 0; i < key.length; i++)
          canonical(key[i], index.collations[i])
      ]);
    }

    String indexCacheId(_Index index) =>
        '${index.name}\u0000${asciiLower(index.table)}\u0000${index.columns.join('\u0000')}\u0000${index.unique}\u0000${index.descending.join(',')}\u0000${index.collations.join('\u0000')}';

    void ensureResidentKeys() {
      final ids = [for (final index in uniqueIndexes) indexCacheId(index)];
      final cachedIds = table.residentKeyIds;
      final cachedRowids = table.residentRowids;
      final same = cachedRowids != null &&
          cachedRowids.length == table.rows.length &&
          cachedIds != null &&
          cachedIds.length == ids.length;
      if (same) {
        var matches = true;
        for (var i = 0; i < ids.length; i++) {
          if (cachedIds[i] != ids[i]) {
            matches = false;
            break;
          }
        }
        if (matches) return;
      }
      final uniques = <String, Set<String>>{};
      for (var i = 0; i < uniqueIndexes.length; i++) {
        final keys = <String>{};
        for (final row in table.rows) {
          final key = keyFor(uniqueIndexes[i], row);
          if (key != null) keys.add(key);
        }
        uniques[ids[i]] = keys;
      }
      table.residentRowids = table.rows.map((row) => row.rowId).toSet();
      table.residentKeyIds = ids;
      table.residentUniques = uniques;
    }

    bool conflictError(SqlConstraintException error, String activePolicy) {
      if (error is SqlDatatypeConstraint) throw error;
      if (activePolicy == 'DEFAULT') activePolicy = error.conflictPolicy;
      if (activePolicy == 'IGNORE') return true;
      if (activePolicy == 'FAIL' || activePolicy == 'ROLLBACK') {
        throw SqlTriggerFailure(activePolicy, error.message);
      }
      throw error;
    }

    TableRow? prepare(TableRow next, String activePolicy) {
      try {
        var defaulted = false;
        final candidate = _row(table, next);

        for (final col in schema.columns) {
          var value = candidate[asciiLower(col.name)];
          final columnPolicy =
              activePolicy == 'DEFAULT' ? col.notNullPolicy : activePolicy;
          if (value == null && col.notNull && columnPolicy == 'REPLACE') {
            value = col.defaultExpression?.evaluate(_constantContext(bound)) ??
                col.defaultValue;
            candidate[asciiLower(col.name)] = _stored(value, col);
            value = candidate[asciiLower(col.name)];
            defaulted = true;
          }
          if (value == null &&
              (col.notNull ||
                  (schema.withoutRowid ||
                          col.strict && col.name != schema.rowidAlias) &&
                      col.primaryKey != 0)) {
            throw SqlConstraintException(
                'NOT NULL constraint failed', null, col.notNullPolicy);
          }
          if (col.strict && value != null) {
            final type = col.declaredType.toUpperCase();
            if (!(type == 'ANY' ||
                ['INT', 'INTEGER'].contains(type) && value is BigInt ||
                type == 'REAL' && (value is BigInt || value is double) ||
                type == 'TEXT' && value is String ||
                type == 'BLOB' && value is Uint8List)) {
              throw const SqlDatatypeConstraint(
                  'STRICT datatype constraint failed');
            }
          }
        }
        if (defaulted) next = _physical(table, candidate, next.rowId);
        final candidateContext = _context(table, next, bound);
        for (final check in [
          ...schema.checks,
          ...schema.columns.expand((c) => c.checks)
        ]) {
          if (truth(check.evaluate(candidateContext), encoding) == false) {
            throw const SqlConstraintException('CHECK constraint failed');
          }
        }

        return next;
      } on SqlConstraintException catch (error) {
        conflictError(error, activePolicy);
        return null;
      }
    }

    Future<void> accept(TableRow next,
        {TableRow? replacing,
        String? overridePolicy,
        bool prepared = false}) async {
      final activePolicy = overridePolicy ?? policy;
      if (!prepared) {
        final candidate = prepare(next, activePolicy);
        if (candidate == null) return;
        next = candidate;
      }
      if (insert &&
          replacing == null &&
          upserts.isEmpty &&
          (activePolicy == 'ABORT' ||
              activePolicy == 'DEFAULT' &&
                  schema.primaryPolicy == 'ABORT' &&
                  schema.autoIndexPolicies.every((p) => p == 'ABORT')) &&
          !other.any((o) =>
              o.type == 'trigger' &&
              asciiLower(o.tableName) == asciiLower(name))) {
        ensureResidentKeys();
        final rowids = table.residentRowids!;
        final ids = table.residentKeyIds!;
        final uniques = table.residentUniques!;
        if (!rowids.add(next.rowId)) {
          throw const SqlConstraintException('UNIQUE constraint failed: rowid');
        }
        final added = <(int, String)>[];
        for (var i = 0; i < uniqueIndexes.length; i++) {
          final key = keyFor(uniqueIndexes[i], next);
          if (key == null) continue;
          if (!uniques[ids[i]]!.add(key)) {
            rowids.remove(next.rowId);
            for (final prior in added) {
              uniques[ids[prior.$1]]!.remove(prior.$2);
            }
            throw const SqlConstraintException('UNIQUE constraint failed');
          }
          added.add((i, key));
        }
        table.rows.add(next);
        if (singleForeignKeyInsert) {
          _validate(foreignKeys: true);
        }
        changes++;
        _changed(
            insertedRowid: insert && !schema.withoutRowid ? next.rowId : null);
        if (replacing == null && insert) last = next.rowId;
        return;
      }
      // Same-rowid update. prepare() already checked this row. Replacing the
      // list entry keeps uniqueness of the primary key, and resident unique
      // keys move from the old values to the new ones.
      if (replacing != null &&
          prepared &&
          next.rowId == replacing.rowId &&
          !schema.withoutRowid &&
          !table.view &&
          (activePolicy == 'ABORT' || activePolicy == 'DEFAULT') &&
          schema.primaryPolicy != 'REPLACE' &&
          schema.autoIndexPolicies.every((item) => item == 'ABORT')) {
        final slot = table.rows.indexOf(replacing);
        if (slot >= 0) {
          ensureResidentKeys();
          final ids = table.residentKeyIds!;
          final uniques = table.residentUniques!;
          final removed = <(int, String)>[];
          final added = <(int, String)>[];
          var conflict = false;
          for (var i = 0; i < uniqueIndexes.length; i++) {
            final oldKey = keyFor(uniqueIndexes[i], replacing);
            final newKey = keyFor(uniqueIndexes[i], next);
            if (oldKey == newKey) continue;
            if (oldKey != null) {
              uniques[ids[i]]!.remove(oldKey);
              removed.add((i, oldKey));
            }
            if (newKey != null && !uniques[ids[i]]!.add(newKey)) {
              conflict = true;
              break;
            }
            if (newKey != null) added.add((i, newKey));
          }
          if (conflict) {
            for (final item in added) {
              uniques[ids[item.$1]]!.remove(item.$2);
            }
            for (final item in removed) {
              uniques[ids[item.$1]]!.add(item.$2);
            }
            throw const SqlConstraintException('UNIQUE constraint failed');
          }
          table.rows[slot] = next;
          changes++;
          _changed();
          return;
        }
      }
      table.invalidateResidentKeys();
      final old = table.rows.toList();
      if (replacing != null) table.rows.remove(replacing);
      final replacingRows = <TableRow>{};
      final conflicts = <(TableRow, String)>[];
      if (!schema.withoutRowid) {
        for (final row in table.rows.where((r) => r.rowId == next.rowId)) {
          conflicts.add((
            row,
            activePolicy == 'DEFAULT' ? schema.primaryPolicy : activePolicy
          ));
        }
      }
      for (final index in uniqueIndexes.reversed) {
        if (!_includes(index, table, next)) continue;
        final key = _indexKey(index, table, next);
        if (key.any((v) => v == null)) continue;
        for (final row in table.rows) {
          if (_includes(index, table, row) &&
              _compare(index, key, _indexKey(index, table, row)) == 0) {
            conflicts.add((
              row,
              activePolicy == 'DEFAULT' ? _indexPolicy(index) : activePolicy
            ));
          }
        }
      }
      // SQLite resolves IGNORE/FAIL/ABORT constraints before deleting REPLACE victims.
      for (final conflict in conflicts) {
        if (conflict.$2 != 'REPLACE') {
          table.rows
            ..clear()
            ..addAll(old);
          conflictError(
              const SqlConstraintException('UNIQUE constraint failed'),
              conflict.$2);
          return;
        }
        replacingRows.add(conflict.$1);
      }
      for (final removed in replacingRows) {
        if (_recursiveTriggers &&
            !await _fire('BEFORE', 'DELETE', table, removed, null, {},
                foreignKeys: foreignKeys, inTransaction: inTransaction)) {
          continue;
        }
        table.rows.remove(removed);
        if (foreignKeys) {
          await _referentialActions(table, removed, null, 0,
              inTransaction: inTransaction);
        }
        if (_recursiveTriggers) {
          await _fire('AFTER', 'DELETE', table, removed, null, {},
              foreignKeys: foreignKeys, inTransaction: inTransaction);
        }
      }
      table.rows.add(next);
      try {
        _validate();
        if (singleForeignKeyInsert && replacing == null) {
          _validate(foreignKeys: true);
        }
      } on SqlConstraintException catch (error) {
        table.rows
          ..clear()
          ..addAll(old);
        conflictError(error, activePolicy);
        return;
      }
      changes++;
      _changed(
          insertedRowid: replacing == null && insert && !schema.withoutRowid
              ? next.rowId
              : null);
      if (replacing == null && insert) last = next.rowId;
    }

    Future<bool> handleUpsert(TableRow excluded) async {
      for (final clause in upserts) {
        TableRow? conflict;
        bool equal(_Index index, TableRow existing) {
          if (!_includes(index, table, excluded) ||
              !_includes(index, table, existing)) {
            return false;
          }
          final key = _indexKey(index, table, excluded);
          return key.every((v) => v != null) &&
              _compare(index, key, _indexKey(index, table, existing)) == 0;
        }

        if (clause.target != null) {
          conflict = table.rows
              .where((row) => clause.index == null
                  ? row.rowId == excluded.rowId
                  : equal(clause.index!, row))
              .firstOrNull;
        } else {
          for (final index in uniqueIndexes.reversed) {
            conflict = table.rows.where((row) => equal(index, row)).firstOrNull;
            if (conflict != null) break;
          }
          if (conflict == null && !schema.withoutRowid) {
            conflict = table.rows
                .where((row) => row.rowId == excluded.rowId)
                .firstOrNull;
          }
        }
        if (conflict == null) continue;
        if (clause.nothing) return true;
        final context = _context(table, conflict, bound);
        final excludedValues = _row(table, excluded);
        for (final entry in excludedValues.entries) {
          context.row['excluded.${entry.key}'] = entry.value;
        }
        for (final col in schema.columns) {
          context.affinities['excluded.${asciiLower(col.name)}'] = col.affinity;
          context.collations['excluded.${asciiLower(col.name)}'] =
              col.collation;
        }
        if (clause.where != null &&
            truth(clause.where!.evaluate(context), encoding) != true) {
          return true;
        }
        final values = _row(table, conflict);
        for (final assignment in clause.assignments.entries) {
          values[assignment.key] = assignment.value.evaluate(context);
        }
        var rowid = conflict.rowId;
        if (schema.rowidAlias != null &&
            clause.assignments.containsKey(asciiLower(schema.rowidAlias!))) {
          rowid = id(values[asciiLower(schema.rowidAlias!)]);
        }
        if (!table.view && !schema.withoutRowid) {
          for (final alias in ['rowid', '_rowid_', 'oid']) {
            if (!columnNames.contains(alias) &&
                clause.assignments.containsKey(alias)) {
              rowid = id(values[alias]);
            }
          }
        }
        final changed = _physical(table, values, rowid);
        final previousPolicy = _conflictPolicies.last;
        _conflictPolicies[_conflictPolicies.length - 1] = 'ABORT';
        try {
          if (!await _fire('BEFORE', 'UPDATE', table, conflict, changed,
              clause.assignments.keys.toSet(),
              foreignKeys: foreignKeys, inTransaction: inTransaction)) {
            return true;
          }
          await accept(changed, replacing: conflict, overridePolicy: 'ABORT');
          emit(changed);
          if (foreignKeys) {
            await _referentialActions(table, conflict, changed, 0,
                inTransaction: inTransaction);
          }
          await _fire('AFTER', 'UPDATE', table, conflict, changed,
              clause.assignments.keys.toSet(),
              foreignKeys: foreignKeys, inTransaction: inTransaction);
          return true;
        } finally {
          _conflictPolicies[_conflictPolicies.length - 1] = previousPolicy;
        }
      }
      return false;
    }

    var insertMax = table.rows.isEmpty
        ? BigInt.zero
        : table.rows.map((r) => r.rowId).reduce((a, b) => a > b ? a : b);
    var sequenceChanged = false;
    if (insert) {
      final triggered = other.any((o) =>
          o.type == 'trigger' && asciiLower(o.tableName) == asciiLower(name));
      BigInt largestRowid() => table.rows.isEmpty
          ? BigInt.zero
          : table.rows.map((r) => r.rowId).reduce((a, b) => a > b ? a : b);
      await for (final expressions in insertQuery == null
          ? Stream.fromIterable(inserts)
          : selectedInsertRows()) {
        if (triggered) insertMax = largestRowid();
        final data = <String, Object?>{};
        final context = _constantContext(bound);
        final singleValues = insertQuery == null && inserts.length == 1;
        if (!singleValues) {
          for (var i = 0; i < input.length; i++) {
            data[input[i]] = expressions[i].evaluate(context);
          }
        }
        for (final column in schema.columns) {
          final key = asciiLower(column.name);
          final slot = singleValues ? input.indexOf(key) : -1;
          if (slot >= 0) {
            data[key] = expressions[slot].evaluate(context);
          } else if (!data.containsKey(key)) {
            // Single VALUES evaluates supplied fields and defaults in declared
            // destination order. Coroutine inputs have already produced their
            // complete row before omitted defaults run.
            data[key] = column.name == schema.rowidAlias ||
                    column.generatedExpression != null
                ? null
                : column.defaultExpression
                        ?.evaluate(EvalContext({}, {}, bound, encoding)) ??
                    column.defaultValue;
          }
        }
        if (singleValues) {
          // An implicit rowid target follows all declared table fields.
          for (var i = 0; i < input.length; i++) {
            if (!data.containsKey(input[i])) {
              data[input[i]] = expressions[i].evaluate(context);
            }
          }
        }
        Object? requested = schema.rowidAlias == null
            ? null
            : data[asciiLower(schema.rowidAlias!)];
        if (!table.view && !schema.withoutRowid) {
          for (final alias in ['rowid', '_rowid_', 'oid']) {
            if (!columnNames.contains(alias) && input.contains(alias)) {
              requested = data[alias];
            }
          }
        }
        if (table.view) {
          final next = _physical(table, data, BigInt.zero);
          if (await _fire('INSTEAD OF', 'INSERT', table, null, next, {},
              foreignKeys: foreignKeys, inTransaction: inTransaction)) {
            emit(next);
          }
          continue;
        }
        final max = insertMax;
        final auto = schema.columns.any((col) => col.autoIncrement);
        final high = auto && (_sequences[asciiLower(name)] ?? BigInt.zero) > max
            ? _sequences[asciiLower(name)]!
            : max;
        var rowid = requested == null ? high + BigInt.one : id(requested);
        final previousChanges = changes;
        var next = _physical(table, data, rowid);
        final before =
            requested == null ? _physical(table, data, -BigInt.one) : next;
        if (!await _fire('BEFORE', 'INSERT', table, null, before, {},
            foreignKeys: foreignKeys, inTransaction: inTransaction)) {
          continue;
        }
        if (requested == null && triggered) {
          final max = largestRowid();
          final sequence = _sequences[asciiLower(name)] ?? BigInt.zero;
          rowid = (auto && sequence > max ? sequence : max) + BigInt.one;
          next = _physical(table, data, rowid);
        }
        if (rowid >= BigInt.one << 63) {
          throw const SqlException('Automatic rowid exhausted');
        }
        final candidate = prepare(next, policy);
        if (candidate == null) continue;
        next = candidate;
        final handled = upserts.isNotEmpty && await handleUpsert(next);
        if (!handled) await accept(next, prepared: true);
        if (!handled && changes > previousChanges) {
          emit(next);
          await _fire('AFTER', 'INSERT', table, null, next, {},
              foreignKeys: foreignKeys, inTransaction: inTransaction);
        }
        if (!handled && changes > previousChanges && rowid > insertMax) {
          insertMax = rowid;
        }
        if (auto && rowid > (_sequences[asciiLower(name)] ?? BigInt.zero)) {
          _sequences[asciiLower(name)] = rowid;
          sequenceChanged = true;
        }
      }
    } else {
      final selected = fromAssignments == null &&
              where != null &&
              queries(where).any(readsTarget)
          ? {
              for (final row in originalRows)
                if (truth(
                        where.evaluate(_context(table, row, bound)
                          ..subquery = snapshotSubquery),
                        encoding) ==
                    true)
                  row
            }
          : null;
      var viewFromIndex = 0;
      final bulkDelete = !update &&
          !table.view &&
          !other.any((object) =>
              object.type == 'trigger' &&
              asciiLower(object.tableName) == asciiLower(name)) &&
          !(foreignKeys &&
              _tables.values.any((child) => child.schema.foreignKeys.any(
                  (key) => asciiLower(key.table) == asciiLower(schema.name))));
      final pendingDelete = <TableRow>[];
      final clearAll = bulkDelete &&
          where == null &&
          fromAssignments == null &&
          viewFromAssignments == null &&
          !hasReturning;
      if (clearAll && table.rows.isNotEmpty) {
        final removed = table.rows.length;
        changes = removed;
        table.rows.clear();
        table.invalidateResidentKeys();
        _counterFrames.lastOrNull?.addChanges(removed);
      }
      for (final row in clearAll
          ? const <TableRow>[]
          : viewFromAssignments?.map((entry) => entry.$1) ?? originalRows) {
        final viewFromValues = viewFromAssignments?[viewFromIndex++].$2;
        final context = _context(table, row, bound);
        if (fromAssignments != null
            ? !fromAssignments.containsKey(row)
            : selected != null
                ? !selected.contains(row)
                : where != null &&
                    truth(where.evaluate(context), encoding) != true) {
          continue;
        }
        if (!bulkDelete && !table.rows.contains(row)) continue;
        if (!update) {
          if (bulkDelete) {
            pendingDelete.add(row);
            changes++;
            _changed();
            emit(row);
            continue;
          }
          if (table.view) {
            if (await _fire('INSTEAD OF', 'DELETE', table, row, null, {},
                foreignKeys: foreignKeys, inTransaction: inTransaction)) {
              emit(row);
            }
            continue;
          }
          if (!await _fire('BEFORE', 'DELETE', table, row, null, {},
              foreignKeys: foreignKeys, inTransaction: inTransaction)) {
            continue;
          }
          table.invalidateResidentKeys();
          table.rows.remove(row);
          if (foreignKeys) {
            await _referentialActions(table, row, null, 0,
                inTransaction: inTransaction);
          }
          changes++;
          _changed();
          emit(row);
          await _fire('AFTER', 'DELETE', table, row, null, {},
              foreignKeys: foreignKeys, inTransaction: inTransaction);
          continue;
        }
        final data = _row(table, row);
        var assignmentIndex = 0;
        for (final assignment in assignments.entries) {
          data[assignment.key] = fromAssignments == null
              ? assignment.value.evaluate(context)
              : (viewFromValues ?? fromAssignments[row]!)[assignmentIndex++];
        }
        var rowid = row.rowId;
        if (schema.rowidAlias != null &&
            assignments.containsKey(asciiLower(schema.rowidAlias!))) {
          rowid = id(data[asciiLower(schema.rowidAlias!)]);
        }
        if (!table.view && !schema.withoutRowid) {
          for (final alias in ['rowid', '_rowid_', 'oid']) {
            if (!columnNames.contains(alias) &&
                assignments.containsKey(alias)) {
              rowid = id(data[alias]);
            }
          }
        }
        var changed = _physical(table, data, rowid);
        if (table.view) {
          if (await _fire('INSTEAD OF', 'UPDATE', table, row, changed,
              assignments.keys.toSet(),
              foreignKeys: foreignKeys, inTransaction: inTransaction)) {
            emit(changed);
          }
          continue;
        }
        if (!await _fire(
            'BEFORE', 'UPDATE', table, row, changed, assignments.keys.toSet(),
            foreignKeys: foreignKeys, inTransaction: inTransaction)) {
          continue;
        }
        final candidate = prepare(changed, policy);
        if (candidate == null) continue;
        changed = candidate;
        final previousChanges = changes;
        await accept(changed, replacing: row, prepared: true);
        if (changes > previousChanges) {
          emit(changed);
          if (foreignKeys && table.rows.contains(changed)) {
            await _referentialActions(table, row, changed, 0,
                inTransaction: inTransaction);
          }
          await _fire(
              'AFTER', 'UPDATE', table, row, changed, assignments.keys.toSet(),
              foreignKeys: foreignKeys, inTransaction: inTransaction);
        }
      }
      if (pendingDelete.isNotEmpty) {
        table.invalidateResidentKeys();
        final dropping = Set<TableRow>.of(pendingDelete);
        table.rows.removeWhere(dropping.contains);
      }
    }
    if (changes == 0 &&
        !sequenceChanged &&
        !other.any((o) => o.type == 'trigger')) {
      return MutationImage(original, 0, null, returned());
    }
    if (deferMaterialize && _canDeferImage) {
      final checkForeignKeys = foreignKeys && _executionDepth == 1;
      final incremental = await _tryIncremental(
          foreignKeys: checkForeignKeys, includeDeferred: !inTransaction);
      if (incremental != null) {
        return MutationImage(
            incremental, changes, insert ? last : null, returned());
      }
      wroteRows = true;
      // NOT NULL, CHECK, and UNIQUE were enforced on the rows this statement
      // changed. Scanning every stored row here made one insert cost grow with
      // the whole table. Foreign-key checks still run inside _tryIncremental
      // when they are due, and a transaction commits them from the live rows.
      return MutationImage(original, changes, insert ? last : null, returned());
    }
    return MutationImage(
        await commit(
            foreignKeys: foreignKeys && _executionDepth == 1,
            includeDeferred: !inTransaction),
        changes,
        insert ? last : null,
        returned());
  }

  /// Ordinary single-table DML may rewrite one rowid tree or patch one overflow
  /// page. Every other shape, including schema changes, falls back to the
  /// compact rebuild.
  /// Image for one autocommit, using a page patch when the row delta allows it.
  Uint8List durableImage() {
    final fast = _fastDurableImage();
    if (fast != null) return fast;
    return serialize(foreignKeys: false, includeDeferred: false);
  }

  Future<Uint8List> commit(
      {required bool foreignKeys, required bool includeDeferred}) async {
    final fast = _fastDurableImage();
    if (fast != null) return fast;
    final incremental = await _tryIncremental(
        foreignKeys: foreignKeys, includeDeferred: includeDeferred);
    if (incremental != null) return incremental;
    return serialize(
        foreignKeys: foreignKeys, includeDeferred: includeDeferred);
  }

  /// One appended, replaced, or deleted row, or one integer-column addend.
  ///
  /// Returns null when the image has to be rebuilt. A hit flushes column
  /// addends so the live rows match the returned bytes.
  Uint8List? _fastDurableImage() {
    if (schemaChanged) return null;
    final addend = _patchAddend();
    if (addend != null) {
      _flushColumnAddends();
      return addend;
    }
    for (final table in _tables.values) {
      final pending = table.columnAddends;
      if (pending != null && pending.isNotEmpty) return null;
    }
    String? changed;
    for (final entry in _tables.entries) {
      if (_sameRowInstances(
          _loadedRows[entry.key] ?? const [], entry.value.rows)) {
        continue;
      }
      if (changed != null ||
          entry.key.startsWith('sqlite_') ||
          entry.value.view ||
          entry.value.schema.withoutRowid ||
          entry.value.schema.virtual ||
          entry.value.schema.rootPage < 0) {
        return null;
      }
      changed = entry.key;
    }
    if (changed == null) return original;
    final table = _tables[changed]!;
    final before = _loadedRows[changed] ?? const <TableRow>[];
    final after = table.rows;
    final root = _tableRoot(table);
    if (root == null) return null;
    if (_indexes.any((index) => asciiLower(index.table) == changed)) {
      return null;
    }
    if (after.isEmpty && before.isNotEmpty) {
      return RowidPagePatch.clearRoot(original, root);
    }
    if (after.length == before.length + 1) {
      for (var i = 0; i < before.length; i++) {
        if (!identical(before[i], after[i])) return null;
      }
      final row = after.last;
      for (final old in before) {
        if (row.rowId <= old.rowId) return null;
      }
      return RowidPagePatch.append(
          original, root, row.rowId, _storedValues(table, row));
    }
    if (after.length + 1 == before.length) {
      var index = 0;
      while (index < after.length && identical(before[index], after[index])) {
        index++;
      }
      for (var i = index; i < after.length; i++) {
        if (!identical(before[i + 1], after[i])) return null;
      }
      return RowidPagePatch.delete(original, root, before[index].rowId);
    }
    if (after.length != before.length) return null;
    var index = -1;
    for (var i = 0; i < after.length; i++) {
      if (identical(before[i], after[i])) continue;
      if (index >= 0 || before[i].rowId != after[i].rowId) return null;
      index = i;
    }
    if (index < 0) return original;
    return RowidPagePatch.replace(
        original, root, after[index].rowId, _storedValues(table, after[index]));
  }

  Uint8List? _patchAddend() {
    String? changed;
    for (final entry in _tables.entries) {
      final addends = entry.value.columnAddends;
      if (addends == null || addends.isEmpty) continue;
      if (changed != null) return null;
      changed = entry.key;
    }
    if (changed == null) return null;
    final table = _tables[changed]!;
    if (table.view ||
        table.schema.withoutRowid ||
        table.schema.virtual ||
        !_sameRowInstances(_loadedRows[changed] ?? const [], table.rows)) {
      return null;
    }
    final stored = table.schema.storageColumns;
    final deltas = <int, BigInt>{};
    for (final entry in table.columnAddends!.entries) {
      if (entry.key < 0 || entry.key >= table.schema.columns.length) {
        return null;
      }
      final column = table.schema.columns[entry.key];
      final slot = stored.indexOf(column);
      if (slot < 0) return null;
      final name = asciiLower(column.name);
      if (name == 'rowid' ||
          name == 'oid' ||
          name == '_rowid_' ||
          name == asciiLower(table.schema.rowidAlias ?? '')) {
        return null;
      }
      if (_indexes.any((index) =>
          asciiLower(index.table) == changed &&
          index.referencedColumns.contains(name))) {
        return null;
      }
      deltas[slot] = entry.value;
    }
    final root = _tableRoot(table);
    if (root == null) return null;
    return RowidPagePatch.addColumns(original, root, deltas);
  }

  int? _tableRoot(_Table table) {
    final declared = table.schema.rootPage;
    if (declared > 1) return declared;
    final roots = RowidPagePatch.schemaRoots(original);
    final root = roots?[asciiLower(table.schema.name)];
    if (root == null || root <= 1) return null;
    return root;
  }

  List<Object?> _storedValues(_Table table, TableRow row) {
    final columns = table.schema.columns;
    return [
      for (final column in table.schema.storageColumns)
        row.values[columns.indexOf(column)]
    ];
  }

  bool _sameRowInstances(List<TableRow> before, List<TableRow> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (!identical(before[i], after[i])) return false;
    }
    return true;
  }

  Future<Uint8List?> _tryIncremental(
      {required bool foreignKeys, required bool includeDeferred}) async {
    if (schemaChanged || other.isNotEmpty) return null;
    // Foreign-key mode also asks for a full row scan. Skip it when no table
    // declares a foreign key; the statement already enforced its own rows.
    if ((foreignKeys || includeDeferred) &&
        _tables.values.any((table) => table.schema.foreignKeys.isNotEmpty)) {
      _validate(foreignKeys: foreignKeys, includeDeferred: includeDeferred);
    }
    final changed = <String>[];
    for (final entry in _tables.entries) {
      final before = _loadedRows[entry.key] ?? const <TableRow>[];
      if (_sameRows(before, entry.value.rows)) continue;
      if (entry.key.startsWith('sqlite_') || entry.value.view) return null;
      changed.add(entry.key);
    }
    if (changed.length != 1) return null;
    final table = _tables[changed.single]!;
    if (table.schema.withoutRowid || table.schema.virtual) return null;
    if (table.schema.columns
        .any((column) => column.generatedExpression != null || column.strict)) {
      return null;
    }
    final indexes = _indexes
        .where((index) => asciiLower(index.table) == changed.single)
        .toList();
    final keysSame = indexes.isEmpty ||
        _indexKeysSame(table, _loadedRows[changed.single] ?? const [],
            table.rows, indexes);
    if (indexes.isNotEmpty && !keysSame) return null;
    if (keysSame) {
      final patched =
          _onePayloadChange(table, _loadedRows[changed.single] ?? const []);
      if (patched != null) {
        try {
          final image = await patchTableOverflow(
              original, table.schema.name, patched.$1, patched.$2);
          if (image != null) return image;
        } on FormatException {
          // Compact rebuild remains available.
        }
      }
    }
    if (!keysSame) return null;
    try {
      return await TableImageWriter.replace(
          original, table.schema.name, table.rows,
          preserveIndexes: indexes.isNotEmpty);
    } on UnsupportedError {
      return null;
    } on FormatException {
      return null;
    }
  }

  (BigInt, List<Object?>)? _onePayloadChange(
      _Table table, List<TableRow> before) {
    if (before.length != table.rows.length) return null;
    final previous = {for (final row in before) row.rowId: row};
    (BigInt, List<Object?>)? found;
    for (final row in table.rows) {
      final old = previous[row.rowId];
      if (old == null) return null;
      if (_sameValues(old.values, row.values)) continue;
      if (found != null) return null;
      found = (row.rowId, row.values);
    }
    return found;
  }

  bool _indexKeysSame(_Table table, List<TableRow> before, List<TableRow> after,
      List<_Index> indexes) {
    if (before.length != after.length) return false;
    final previous = {for (final row in before) row.rowId: row};
    for (final row in after) {
      final old = previous[row.rowId];
      if (old == null) return false;
      for (final index in indexes) {
        for (final column in index.referencedColumns) {
          if (!_sameValue(_columnValue(table, old, column),
              _columnValue(table, row, column))) {
            return false;
          }
        }
      }
    }
    return true;
  }

  Object? _columnValue(_Table table, TableRow row, String column) {
    if (table.schema.rowidAlias != null &&
        asciiLower(table.schema.rowidAlias!) == column) {
      return row.rowId;
    }
    final index = table.schema.columns
        .indexWhere((candidate) => asciiLower(candidate.name) == column);
    if (index < 0 || index >= row.values.length) return null;
    return row.values[index];
  }

  bool _sameRows(List<TableRow> before, List<TableRow> after) {
    if (before.length != after.length) return false;
    final previous = {for (final row in before) row.rowId: row};
    if (previous.length != before.length) return false;
    for (final row in after) {
      final old = previous[row.rowId];
      if (old == null || !_sameValues(old.values, row.values)) return false;
    }
    return true;
  }

  bool _sameValues(List<Object?> before, List<Object?> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (!_sameValue(before[i], after[i])) return false;
    }
    return true;
  }

  bool _sameValue(Object? before, Object? after) {
    if (before is Uint8List && after is Uint8List) {
      if (before.length != after.length) return false;
      for (var i = 0; i < before.length; i++) {
        if (before[i] != after[i]) return false;
      }
      return true;
    }
    return before == after;
  }

  static final RegExp _freelistWriterRefusal = RegExp(
      r'\b(NOT|UNIQUE|CHECK|REFERENCES|DEFAULT|COLLATE|AUTOINCREMENT|GENERATED|CONSTRAINT)\b',
      caseSensitive: false);

  static final RegExp _directInsertPattern = RegExp(
      r'^INSERT\s+INTO\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\)\s*VALUES\s*\(\s*(\?(?:\s*,\s*\?)*)\s*\)\s*;?\s*$',
      caseSensitive: false);
  static final RegExp _fastReadPattern = RegExp(
      r'^SELECT\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s+FROM\s+([A-Za-z_][A-Za-z0-9_]*)\s+WHERE\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\?\s*;?\s*$',
      caseSensitive: false);

  void _flushColumnAddends() {
    for (final table in _tables.values) {
      final addends = table.columnAddends;
      if (addends == null || addends.isEmpty) continue;
      for (var index = 0; index < table.rows.length; index++) {
        final row = table.rows[index];
        final values = List<Object?>.of(row.values);
        for (final entry in addends.entries) {
          values[entry.key] = _addStored(values[entry.key], entry.value);
        }
        table.rows[index] = TableRow(row.rowId, values);
      }
      table.columnAddends = null;
      table.invalidateResidentKeys();
    }
  }

  Object? _addStored(Object? value, BigInt addend) {
    if (value == null) return null;
    if (value is BigInt) return value + addend;
    if (value is int) return BigInt.from(value) + addend;
    if (value is double) return value + addend.toDouble();
    final number = numeric(value, prefix: true, encoding: encoding);
    if (number is BigInt) return number + addend;
    if (number is double) return number + addend.toDouble();
    if (number == null && value is String) return addend;
    return value;
  }

  bool _simpleTable(_Table table, {required bool foreignKeys}) {
    if (table.view || table.schema.withoutRowid || table.schema.virtual) {
      return false;
    }
    if (table.schema.checks.isNotEmpty ||
        table.schema.columns.any((column) =>
            column.checks.isNotEmpty ||
            column.generatedExpression != null ||
            column.strict)) {
      return false;
    }
    if (foreignKeys && table.schema.foreignKeys.isNotEmpty) return false;
    final name = asciiLower(table.schema.name);
    if (other.any((object) =>
        object.type == 'trigger' && asciiLower(object.tableName) == name)) {
      return false;
    }
    return true;
  }

  (String, String, BigInt)? _scanBulkIncrement(String sql) {
    var i = 0;
    final n = sql.length;
    void skip() {
      while (i < n) {
        final unit = sql.codeUnitAt(i);
        if (unit != 32 && unit != 9 && unit != 10 && unit != 13) break;
        i++;
      }
    }

    bool word(String upper) {
      skip();
      if (i + upper.length > n) return false;
      for (var k = 0; k < upper.length; k++) {
        var unit = sql.codeUnitAt(i + k);
        if (unit >= 97 && unit <= 122) unit -= 32;
        if (unit != upper.codeUnitAt(k)) return false;
      }
      final end = i + upper.length;
      if (end < n) {
        final next = sql.codeUnitAt(end);
        final identifier = (next >= 65 && next <= 90) ||
            (next >= 97 && next <= 122) ||
            (next >= 48 && next <= 57) ||
            next == 95;
        if (identifier) return false;
      }
      i = end;
      return true;
    }

    String? ident() {
      skip();
      if (i >= n) return null;
      final start = i;
      var unit = sql.codeUnitAt(i);
      final letter = (unit >= 65 && unit <= 90) ||
          (unit >= 97 && unit <= 122) ||
          unit == 95;
      if (!letter) return null;
      i++;
      while (i < n) {
        unit = sql.codeUnitAt(i);
        final identifier = (unit >= 65 && unit <= 90) ||
            (unit >= 97 && unit <= 122) ||
            (unit >= 48 && unit <= 57) ||
            unit == 95;
        if (!identifier) break;
        i++;
      }
      return sql.substring(start, i);
    }

    if (!word('UPDATE')) return null;
    final table = ident();
    if (table == null || !word('SET')) return null;
    final column = ident();
    if (column == null) return null;
    skip();
    if (i >= n || sql.codeUnitAt(i) != 0x3d) return null;
    i++;
    final right = ident();
    if (right == null || asciiLower(right) != asciiLower(column)) return null;
    skip();
    if (i >= n || sql.codeUnitAt(i) != 0x2b) return null;
    i++;
    skip();
    if (i >= n) return null;
    final numberStart = i;
    var unit = sql.codeUnitAt(i);
    if (unit < 48 || unit > 57) return null;
    i++;
    while (i < n) {
      unit = sql.codeUnitAt(i);
      if (unit < 48 || unit > 57) break;
      i++;
    }
    final addend = BigInt.parse(sql.substring(numberStart, i));
    skip();
    if (i < n && sql.codeUnitAt(i) == 0x3b) {
      i++;
      skip();
    }
    if (i != n) return null;
    return (table, column, addend);
  }

  (String, String, BigInt, String)? _scanIncrementWhere(String sql) {
    final parsed = _scanAssignment(sql);
    if (parsed == null) return null;
    return (parsed.$1, parsed.$2, parsed.$3, parsed.$4);
  }

  (String, String)? _scanDeleteWhere(String sql) {
    final head = _leadingWords(sql, const ['DELETE', 'FROM']);
    if (head == null) return null;
    final table = head.$1;
    var i = head.$2;
    if (!_wordAt(sql, i, 'WHERE')) return null;
    i = _afterWord(sql, i, 'WHERE');
    final column = _identAt(sql, i);
    if (column == null) return null;
    i = column.$2;
    i = _skipSpace(sql, i);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x3d) return null;
    i = _skipSpace(sql, i + 1);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x3f) return null;
    i = _skipSpace(sql, i + 1);
    if (i < sql.length && sql.codeUnitAt(i) == 0x3b) {
      i = _skipSpace(sql, i + 1);
    }
    if (i != sql.length) return null;
    return (table, column.$1);
  }

  (String, String, BigInt, String)? _scanAssignment(String sql) {
    final head = _leadingWords(sql, const ['UPDATE']);
    if (head == null) return null;
    final table = head.$1;
    var i = head.$2;
    if (!_wordAt(sql, i, 'SET')) return null;
    i = _afterWord(sql, i, 'SET');
    final column = _identAt(sql, i);
    if (column == null) return null;
    i = _skipSpace(sql, column.$2);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x3d) return null;
    final right = _identAt(sql, i + 1);
    if (right == null || asciiLower(right.$1) != asciiLower(column.$1)) {
      return null;
    }
    i = _skipSpace(sql, right.$2);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x2b) return null;
    i = _skipSpace(sql, i + 1);
    if (i >= sql.length) return null;
    final numberStart = i;
    var unit = sql.codeUnitAt(i);
    if (unit < 48 || unit > 57) return null;
    i++;
    while (i < sql.length) {
      unit = sql.codeUnitAt(i);
      if (unit < 48 || unit > 57) break;
      i++;
    }
    final addend = BigInt.parse(sql.substring(numberStart, i));
    if (!_wordAt(sql, i, 'WHERE')) return null;
    i = _afterWord(sql, i, 'WHERE');
    final filter = _identAt(sql, i);
    if (filter == null) return null;
    i = _skipSpace(sql, filter.$2);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x3d) return null;
    i = _skipSpace(sql, i + 1);
    if (i >= sql.length || sql.codeUnitAt(i) != 0x3f) return null;
    i = _skipSpace(sql, i + 1);
    if (i < sql.length && sql.codeUnitAt(i) == 0x3b) {
      i = _skipSpace(sql, i + 1);
    }
    if (i != sql.length) return null;
    return (table, column.$1, addend, filter.$1);
  }

  (String, int)? _leadingWords(String sql, List<String> words) {
    var i = 0;
    String? ident;
    for (final word in words) {
      if (!_wordAt(sql, i, word)) return null;
      i = _afterWord(sql, i, word);
    }
    final name = _identAt(sql, i);
    if (name == null) return null;
    ident = name.$1;
    return (ident, name.$2);
  }

  int _skipSpace(String sql, int index) {
    var i = index;
    while (i < sql.length) {
      final unit = sql.codeUnitAt(i);
      if (unit != 32 && unit != 9 && unit != 10 && unit != 13) break;
      i++;
    }
    return i;
  }

  bool _wordAt(String sql, int index, String upper) {
    final i = _skipSpace(sql, index);
    if (i + upper.length > sql.length) return false;
    for (var k = 0; k < upper.length; k++) {
      var unit = sql.codeUnitAt(i + k);
      if (unit >= 97 && unit <= 122) unit -= 32;
      if (unit != upper.codeUnitAt(k)) return false;
    }
    final end = i + upper.length;
    if (end < sql.length) {
      final next = sql.codeUnitAt(end);
      final identifier = (next >= 65 && next <= 90) ||
          (next >= 97 && next <= 122) ||
          (next >= 48 && next <= 57) ||
          next == 95;
      if (identifier) return false;
    }
    return true;
  }

  int _afterWord(String sql, int index, String upper) {
    final i = _skipSpace(sql, index);
    return i + upper.length;
  }

  (String, int)? _identAt(String sql, int index) {
    final i = _skipSpace(sql, index);
    if (i >= sql.length) return null;
    var unit = sql.codeUnitAt(i);
    final letter =
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95;
    if (!letter) return null;
    var end = i + 1;
    while (end < sql.length) {
      unit = sql.codeUnitAt(end);
      final identifier = (unit >= 65 && unit <= 90) ||
          (unit >= 97 && unit <= 122) ||
          (unit >= 48 && unit <= 57) ||
          unit == 95;
      if (!identifier) break;
      end++;
    }
    return (sql.substring(i, end), end);
  }

  String? _scanDeleteAll(String sql) {
    var i = 0;
    final n = sql.length;
    void skip() {
      while (i < n) {
        final unit = sql.codeUnitAt(i);
        if (unit != 32 && unit != 9 && unit != 10 && unit != 13) break;
        i++;
      }
    }

    bool word(String upper) {
      skip();
      if (i + upper.length > n) return false;
      for (var k = 0; k < upper.length; k++) {
        var unit = sql.codeUnitAt(i + k);
        if (unit >= 97 && unit <= 122) unit -= 32;
        if (unit != upper.codeUnitAt(k)) return false;
      }
      final end = i + upper.length;
      if (end < n) {
        final next = sql.codeUnitAt(end);
        final identifier = (next >= 65 && next <= 90) ||
            (next >= 97 && next <= 122) ||
            (next >= 48 && next <= 57) ||
            next == 95;
        if (identifier) return false;
      }
      i = end;
      return true;
    }

    String? ident() {
      skip();
      if (i >= n) return null;
      var unit = sql.codeUnitAt(i);
      final letter = (unit >= 65 && unit <= 90) ||
          (unit >= 97 && unit <= 122) ||
          unit == 95;
      if (!letter) return null;
      final start = i;
      i++;
      while (i < n) {
        unit = sql.codeUnitAt(i);
        final identifier = (unit >= 65 && unit <= 90) ||
            (unit >= 97 && unit <= 122) ||
            (unit >= 48 && unit <= 57) ||
            unit == 95;
        if (!identifier) break;
        i++;
      }
      return sql.substring(start, i);
    }

    if (!word('DELETE') || !word('FROM')) return null;
    final table = ident();
    if (table == null) return null;
    skip();
    if (i < n && sql.codeUnitAt(i) == 0x3b) {
      i++;
      skip();
    }
    if (i != n) return null;
    return table;
  }

  MutationImage? _tryDeleteAll(String sql, {required bool foreignKeys}) {
    final tableName = _scanDeleteAll(sql.trim());
    if (tableName == null) return null;
    final key = asciiLower(tableName);
    final table = _tables[key];
    if (table == null || !_simpleTable(table, foreignKeys: foreignKeys)) {
      return null;
    }
    if (foreignKeys &&
        _tables.values.any((child) => child.schema.foreignKeys
            .any((fk) => asciiLower(fk.table) == key))) {
      return null;
    }
    final removed = table.rows.length;
    table.rows.clear();
    table.columnAddends = null;
    table.invalidateResidentKeys();
    wroteRows = removed > 0;
    // The in-place writer refuses NOT NULL, UNIQUE, and the other tokens in
    // its pattern, and it cannot keep a secondary index. Those tables compact
    // on the next read, so a refused rebuild must not run inside this statement.
    final indexed = _indexes.any((index) => asciiLower(index.table) == key);
    releaseFreedPages =
        removed > 0 && !indexed && !_freelistWriterRefusal.hasMatch(table.sql);
    _beginCounters();
    _counterFrames.lastOrNull?.addChanges(removed);
    return MutationImage(original, removed, null);
  }

  MutationImage? _tryBulkIncrement(String sql, List<Object?> parameters,
      {required bool foreignKeys}) {
    if (parameters.isNotEmpty) return null;
    final match = _scanBulkIncrement(sql.trim());
    if (match == null) return null;
    final table = _tables[asciiLower(match.$1)];
    if (table == null || !_simpleTable(table, foreignKeys: foreignKeys)) {
      return null;
    }
    final columnName = asciiLower(match.$2);
    if (columnName == 'rowid' ||
        columnName == 'oid' ||
        columnName == '_rowid_' ||
        columnName == asciiLower(table.schema.rowidAlias ?? '')) {
      return null;
    }
    final column = table.schema.columns
        .indexWhere((candidate) => asciiLower(candidate.name) == columnName);
    // INTEGER affinity is reported as numeric. Only a declared type that
    // contains INT stores the addend as an integer; REAL and NUMERIC stay on
    // the general planner.
    if (column < 0 ||
        !table.schema.columns[column].declaredType
            .toUpperCase()
            .contains('INT')) {
      return null;
    }
    final addend = match.$3;
    final current = table.columnAddends ?? <int, BigInt>{};
    current[column] = (current[column] ?? BigInt.zero) + addend;
    table.columnAddends = current;
    table.valueIndexes?.remove(column);
    wroteRows = true;
    final count = table.rows.length;
    _beginCounters();
    _counterFrames.lastOrNull?.addChanges(count);
    return MutationImage(original, count, null);
  }

  MutationImage? _tryHotRowIncrement(String sql, List<Object?> parameters,
      {required bool foreignKeys}) {
    if (parameters.length != 1) return null;
    final match = _scanIncrementWhere(sql.trim());
    if (match == null) return null;
    final table = _tables[asciiLower(match.$1)];
    if (table == null || !_simpleTable(table, foreignKeys: foreignKeys)) {
      return null;
    }
    if (!_isRowidName(table, asciiLower(match.$4))) return null;
    final columnName = asciiLower(match.$2);
    if (_isRowidName(table, columnName)) return null;
    final column = table.schema.columns
        .indexWhere((candidate) => asciiLower(candidate.name) == columnName);
    if (column < 0 ||
        !table.schema.columns[column].declaredType
            .toUpperCase()
            .contains('INT')) {
      return null;
    }
    if (_indexes.any((index) =>
        asciiLower(index.table) == asciiLower(table.schema.name) &&
        index.referencedColumns.contains(columnName))) {
      return null;
    }
    final rowId = _fastRowid(sqlValue(parameters.single));
    if (rowId == null) return null;
    final existing = _rowById(table)[rowId];
    if (existing == null) {
      _beginCounters();
      return MutationImage(original, 0, null);
    }
    final current = existing.values[column];
    if (current is! BigInt && current is! int) return null;
    final stored = current is BigInt ? current : BigInt.from(current as int);
    final values = List<Object?>.of(existing.values);
    values[column] = stored + match.$3;
    final updated = TableRow(rowId, values);
    final index = table.rows.indexOf(existing);
    if (index < 0) return null;
    table.rows[index] = updated;
    table.rowById![rowId] = updated;
    table.valueIndexes?.remove(column);
    wroteRows = true;
    _beginCounters();
    _changed();
    return MutationImage(original, 1, null);
  }

  MutationImage? _tryHotDeleteRow(String sql, List<Object?> parameters,
      {required bool foreignKeys}) {
    if (parameters.length != 1) return null;
    final match = _scanDeleteWhere(sql.trim());
    if (match == null) return null;
    final key = asciiLower(match.$1);
    final table = _tables[key];
    if (table == null || !_simpleTable(table, foreignKeys: foreignKeys)) {
      return null;
    }
    if (!_isRowidName(table, asciiLower(match.$2))) return null;
    if (_indexes.any((index) => asciiLower(index.table) == key)) return null;
    if (foreignKeys &&
        _tables.values.any((child) => child.schema.foreignKeys
            .any((fk) => asciiLower(fk.table) == key))) {
      return null;
    }
    final rowId = _fastRowid(sqlValue(parameters.single));
    if (rowId == null) return null;
    final existing = _rowById(table)[rowId];
    if (existing == null) {
      _beginCounters();
      return MutationImage(original, 0, null);
    }
    table.rows.remove(existing);
    table.rowById!.remove(rowId);
    table.residentRowids?.remove(rowId);
    table.valueIndexes = null;
    wroteRows = true;
    _beginCounters();
    _changed();
    return MutationImage(original, 1, null);
  }

  /// Repeated single-row inserts and whole-table integer increments.
  ///
  /// Returns null when the statement needs the general planner. A hit does not
  /// take a statement snapshot: the row is appended only after every check, so
  /// a constraint failure leaves the live rows unchanged.
  bool _vacuumNoOp() {
    for (final table in _tables.values) {
      if (table.view || table.schema.virtual) return false;
      if (table.schema.withoutRowid || table.schema.rowidAlias != null) {
        continue;
      }
      if (_indexes.any((index) =>
          asciiLower(index.table) == asciiLower(table.schema.name))) {
        continue;
      }
      if (table.rows.isNotEmpty) return false;
    }
    return DatabaseHeader.decode(original).freelistPages == 0;
  }

  MutationImage? tryHotDml(String sql, List<Object?> parameters,
      {required bool foreignKeys,
      required bool inTransaction,
      required SqlConnectionState counters}) {
    if (_executionDepth != 0) return null;
    releaseFreedPages = false;
    final text = sql.trim();
    if (text.isEmpty) return null;
    final head = text.codeUnitAt(0);
    final insert = head == 0x49 || head == 0x69;
    final update = head == 0x55 || head == 0x75;
    final vacuum = head == 0x56 || head == 0x76;
    final delete = head == 0x44 || head == 0x64;
    if (update) {
      if (parameters.length > 1) return null;
      if (parameters.length == 1 && _scanIncrementWhere(text) == null) {
        return null;
      }
    } else if (insert) {
      if (parameters.isEmpty) return null;
      if (_fastInsertPlans[text] == null &&
          !_directInsertPattern.hasMatch(text)) {
        return null;
      }
    } else if (vacuum) {
      if (parameters.isNotEmpty || inTransaction) return null;
      final upper = text.toUpperCase();
      if (upper != 'VACUUM' && upper != 'VACUUM;') return null;
      if (!_vacuumNoOp()) return null;
    } else if (delete) {
      if (parameters.length > 1) return null;
      if (parameters.isEmpty && _scanDeleteAll(text) == null) return null;
      if (parameters.length == 1 && _scanDeleteWhere(text) == null) {
        return null;
      }
    } else {
      return null;
    }
    _executionDepth = 1;
    _counterFrames.add(counters.beginStatement());
    try {
      if (vacuum) {
        _counterFrames.last?.finish();
        return MutationImage(original, 0, null);
      }
      if (update) {
        if (parameters.isNotEmpty) {
          final one =
              _tryHotRowIncrement(text, parameters, foreignKeys: foreignKeys);
          if (one == null) return null;
          _counterFrames.last?.finish();
          return one;
        }
        final bulk =
            _tryBulkIncrement(text, parameters, foreignKeys: foreignKeys);
        if (bulk == null) return null;
        _counterFrames.last?.finish();
        return bulk;
      }
      if (delete) {
        if (parameters.isNotEmpty) {
          final one =
              _tryHotDeleteRow(text, parameters, foreignKeys: foreignKeys);
          if (one == null) return null;
          _counterFrames.last?.finish();
          return one;
        }
        final removed = _tryDeleteAll(text, foreignKeys: foreignKeys);
        if (removed == null) return null;
        _counterFrames.last?.finish();
        return removed;
      }
      _flushColumnAddends();
      final inserted =
          _tryDirectInsert(text, parameters, foreignKeys: foreignKeys);
      if (inserted == null) return null;
      _counterFrames.last?.finish();
      return inserted;
    } catch (_) {
      _counterFrames.last?.finish(retainChanges: false);
      rethrow;
    } finally {
      _executionDepth = 0;
      _counterFrames.removeLast();
    }
  }

  int _fastToken(_Table table) {
    final name = asciiLower(table.schema.name);
    var token = _indexes.length * 31 + other.length;
    token = token * 31 + table.schema.checks.length;
    token = token * 31 + table.schema.foreignKeys.length;
    token = token * 31 + table.schema.columns.length;
    token = token * 31 + table.schema.autoIndexPolicies.length;
    if (table.schema.primaryPolicy != 'ABORT') token += 101;
    for (final policy in table.schema.autoIndexPolicies) {
      if (policy != 'ABORT') token += 103;
    }
    for (final index in _indexes) {
      if (index.unique && asciiLower(index.table) == name) token += 17;
    }
    return token;
  }

  MutationImage? _tryDirectInsert(String sql, List<Object?> parameters,
      {required bool foreignKeys}) {
    final text = sql.trim();
    final cached = _fastInsertPlans[text];
    if (cached != null) {
      final table = _tables[cached.tableKey];
      if (table == null || cached.token != _fastToken(table)) {
        _fastInsertPlans.remove(text);
      } else if (parameters.length != cached.arity ||
          foreignKeys && table.schema.foreignKeys.isNotEmpty) {
        return null;
      } else {
        return _commitFastInsert(table, cached, parameters);
      }
    }
    final match = _directInsertPattern.firstMatch(text);
    if (match == null) return null;
    final table = _tables[asciiLower(match.group(1)!)];
    if (table == null || !_simpleTable(table, foreignKeys: foreignKeys)) {
      return null;
    }
    if (table.schema.primaryPolicy != 'ABORT' ||
        table.schema.autoIndexPolicies.any((policy) => policy != 'ABORT')) {
      return null;
    }
    final name = asciiLower(table.schema.name);
    if (_indexes
        .any((index) => index.unique && asciiLower(index.table) == name)) {
      return null;
    }
    final columns = match
        .group(2)!
        .split(',')
        .map((column) => asciiLower(column.trim()))
        .toList();
    final placeholders = match.group(3)!.split(',').length;
    if (columns.length != placeholders ||
        parameters.length != columns.length ||
        columns.toSet().length != columns.length) {
      return null;
    }
    final alias = asciiLower(table.schema.rowidAlias ?? '');
    if (alias.isEmpty || !columns.contains(alias)) return null;
    final parametersByColumn = <int>[];
    final columnIndexes = <int>[];
    var rowidParameter = -1;
    for (var i = 0; i < columns.length; i++) {
      if (columns[i] == alias) {
        rowidParameter = i;
        continue;
      }
      final index = table.schema.columns
          .indexWhere((column) => asciiLower(column.name) == columns[i]);
      if (index < 0) return null;
      parametersByColumn.add(i);
      columnIndexes.add(index);
    }
    if (rowidParameter < 0) return null;
    for (var index = 0; index < table.schema.columns.length; index++) {
      final column = table.schema.columns[index];
      if (asciiLower(column.name) == alias || columnIndexes.contains(index)) {
        continue;
      }
      if (column.notNull ||
          column.defaultValue != null ||
          column.defaultExpression != null ||
          column.defaultSql != null) {
        return null;
      }
    }
    final plan = _FastInsertPlan(
        tableKey: name,
        token: _fastToken(table),
        rowidParameter: rowidParameter,
        parameters: parametersByColumn,
        columns: columnIndexes,
        arity: columns.length);
    _fastInsertPlans[text] = plan;
    return _commitFastInsert(table, plan, parameters);
  }

  MutationImage? _commitFastInsert(
      _Table table, _FastInsertPlan plan, List<Object?> parameters) {
    final rowId = _fastRowid(sqlValue(parameters[plan.rowidParameter]));
    if (rowId == null) return null;
    final values = List<Object?>.filled(table.schema.columns.length, null);
    for (var i = 0; i < plan.parameters.length; i++) {
      final column = table.schema.columns[plan.columns[i]];
      var stored = _stored(sqlValue(parameters[plan.parameters[i]]), column);
      if (stored is BigInt) {
        final type = column.declaredType.toUpperCase();
        if (!type.contains('INT') &&
            ['REAL', 'FLOA', 'DOUB'].any(type.contains)) {
          stored = stored.toDouble();
        }
      }
      if (column.notNull && stored == null) return null;
      values[plan.columns[i]] = stored;
    }
    final rowids = table.residentRowids;
    if (rowids == null || rowids.length != table.rows.length) {
      table.residentRowids = table.rows.map((row) => row.rowId).toSet();
    }
    _beginCounters();
    if (table.residentRowids!.contains(rowId)) {
      throw const SqlConstraintException('UNIQUE constraint failed: rowid');
    }
    final row = TableRow(rowId, values);
    if (!table.residentRowids!.add(rowId)) {
      throw const SqlConstraintException('UNIQUE constraint failed: rowid');
    }
    table.rows.add(row);
    table.rowById = null;
    table.valueIndexes = null;
    wroteRows = true;
    _changed(insertedRowid: rowId);
    return MutationImage(original, 1, rowId);
  }

  BigInt? _fastRowid(Object? value) {
    if (value is String) value = numeric(value, encoding: encoding);
    if (value is int) value = BigInt.from(value);
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble() &&
        value > -(BigInt.one << 63).toDouble() &&
        value < (BigInt.one << 63).toDouble()) {
      value = BigInt.from(value);
    }
    if (value is! BigInt ||
        value < -(BigInt.one << 63) ||
        value >= BigInt.one << 63) {
      return null;
    }
    return value;
  }

  /// A repeated single-table equality read answered from the live rows.
  QueryResult? tryFastRead(String sql, List<Object?> parameters) {
    if (parameters.length != 1) return null;
    final match = _fastReadPattern.firstMatch(sql.trim());
    if (match == null) return null;
    final table = _tables[asciiLower(match.group(2)!)];
    if (table == null || table.view || table.schema.virtual) return null;
    final selected = match
        .group(1)!
        .split(',')
        .map((column) => asciiLower(column.trim()))
        .toList();
    final filter = asciiLower(match.group(3)!);
    final columns = <CatalogColumn?>[];
    for (final name in selected) {
      final column = _fastColumn(table, name);
      if (column == null && !_isRowidName(table, name)) return null;
      if (column != null &&
          column.collation != 'BINARY' &&
          column.collation != 'binary') {
        return null;
      }
      columns.add(column);
    }
    final filterColumn = _fastColumn(table, filter);
    final filterIsRowid = _isRowidName(table, filter);
    if (filterColumn == null && !filterIsRowid) return null;
    if (filterColumn != null &&
        filterColumn.collation != 'BINARY' &&
        filterColumn.collation != 'binary') {
      return null;
    }
    if (filterColumn != null &&
        table.columnAddends != null &&
        table.columnAddends!
            .containsKey(table.schema.columns.indexOf(filterColumn))) {
      _flushColumnAddends();
    }
    final bound = sqlValue(parameters.single);
    final List<TableRow> matches;
    if (filterIsRowid) {
      if (bound == null) {
        matches = const [];
      } else {
        final rowId = _fastRowid(bound);
        if (rowId == null) return null;
        final row = _rowById(table)[rowId];
        matches = row == null ? const [] : [row];
      }
    } else {
      if (bound == null) {
        matches = const [];
      } else if (bound is! String && bound is! BigInt && bound is! double) {
        return null;
      } else {
        final columnIndex = table.schema.columns.indexOf(filterColumn!);
        final index = _valueIndex(table, columnIndex);
        if (index.isNotEmpty && !index.containsKey(bound)) {
          final sample = index.keys.first;
          if (sample.runtimeType != bound.runtimeType) return null;
        }
        matches = index[bound] ?? const [];
      }
    }
    final ordered = matches.length < 2
        ? matches
        : ([...matches]..sort((a, b) => a.rowId.compareTo(b.rowId)));
    final labels =
        match.group(1)!.split(',').map((column) => column.trim()).toList();
    final rows = [
      for (final row in ordered)
        [
          for (var i = 0; i < columns.length; i++)
            columns[i] == null
                ? row.rowId
                : _projected(
                    table, row, table.schema.columns.indexOf(columns[i]!))
        ]
    ];
    return QueryResult(
        labels,
        rows,
        [for (final column in columns) column?.affinity ?? 'integer'],
        [for (final column in columns) column?.declaredType ?? 'INTEGER'],
        [for (final column in columns) column?.collation ?? 'BINARY']);
  }

  CatalogColumn? _fastColumn(_Table table, String name) {
    for (final column in table.schema.columns) {
      if (asciiLower(column.name) == name) return column;
    }
    return null;
  }

  bool _isRowidName(_Table table, String name) =>
      name == 'rowid' ||
      name == 'oid' ||
      name == '_rowid_' ||
      name.isNotEmpty && name == asciiLower(table.schema.rowidAlias ?? '');

  Map<BigInt, TableRow> _rowById(_Table table) {
    final cached = table.rowById;
    if (cached != null && cached.length == table.rows.length) return cached;
    return table.rowById = {for (final row in table.rows) row.rowId: row};
  }

  Map<Object, List<TableRow>> _valueIndex(_Table table, int column) {
    final indexes = table.valueIndexes ??= {};
    final cached = indexes[column];
    if (cached != null) return cached;
    final built = <Object, List<TableRow>>{};
    for (final row in table.rows) {
      final value = row.values[column];
      if (value == null) continue;
      final key = value is int ? BigInt.from(value) : value;
      if (key is! String && key is! BigInt && key is! double) continue;
      (built[key] ??= []).add(row);
    }
    return indexes[column] = built;
  }

  Object? _projected(_Table table, TableRow row, int column) {
    final schemaColumn = table.schema.columns[column];
    if (table.schema.rowidAlias != null &&
        schemaColumn.name == table.schema.rowidAlias) {
      return row.rowId;
    }
    final addend = table.columnAddends?[column];
    final value = row.values[column];
    if (addend == null || addend == BigInt.zero) return value;
    return _addStored(value, addend);
  }
}
