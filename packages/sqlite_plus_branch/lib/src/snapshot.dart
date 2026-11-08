part of '../sqlite_plus_branch.dart';

const _receiptTable = '_spb_merges';
const _receiptSql =
    'CREATE TABLE _spb_merges(branch_id TEXT PRIMARY KEY NOT NULL,source_id TEXT NOT NULL,branch_hash TEXT NOT NULL)';

final class _Table {
  _Table(this.name, this.columns, this.keys, this.keyTypes, this.rows);
  final String name;
  final List<String> columns, keys, keyTypes;
  final Map<String, Map<String, Object?>> rows;
  Map<String, Object?> key(Map<String, Object?> row) =>
      {for (final k in keys) k: row[k]};
  String identity(Map<String, Object?> row) =>
      jsonEncode(keys.map((k) => _wire(row[k])).toList());
}

final class _Snapshot {
  _Snapshot(this.schema, this.tables);
  final String schema;
  final Map<String, _Table> tables;
}

Uint8List _image(MutableSqliteDatabase db, BranchLimits limits) {
  if (db.inTransaction) {
    throw const BranchException('Caller transaction must finish first');
  }
  final image = db.exportImage();
  if (image.length > limits.maxImageBytes) {
    throw const BranchException('Image budget exceeded');
  }
  return image;
}

Future<_Snapshot> _snapshot(Uint8List image, BranchLimits limits) async {
  final db = await MutableSqliteDatabase.fromImage(image);
  try {
    final schemaRows = (await db.query(
            'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name'))
        .rows;
    final schema = <List<Object?>>[];
    final tables = <String, _Table>{};
    var rowCount = 0;
    for (final entry in schemaRows) {
      final kind = entry[0] as String, name = entry[1] as String;
      final sql = entry[3] as String?;
      if (name == _receiptTable) {
        if (kind != 'table' || sql != _receiptSql) {
          throw const BranchException('Reserved receipt schema mismatch');
        }
        continue;
      }
      if (kind == 'trigger') {
        throw const BranchException('Triggers are not supported in branch v1');
      }
      if ((entry[2] as String) == _receiptTable) continue;
      if (name.toLowerCase().startsWith('_spb_')) {
        throw const BranchException('Reserved _spb_ name');
      }
      // sqlite_sequence/statistics are physical bookkeeping, never row merge targets.
      if (name.startsWith('sqlite_')) continue;
      schema.add(entry);
      if (kind != 'table') continue;
      if (tables.length >= limits.maxTables) {
        throw const BranchException('Table budget exceeded');
      }
      if (sql!.toUpperCase().contains('CREATE VIRTUAL TABLE')) {
        throw const BranchException('Virtual tables are not supported');
      }
      final parsed = DatabaseCatalog.parseTable(sql, 1);
      if (parsed.virtualModule != null) {
        throw const BranchException('Virtual tables are not supported');
      }
      if (parsed.columns.any((c) => c.generatedExpression != null)) {
        throw const BranchException('Generated columns are not supported');
      }
      final columns = parsed.columns.map((c) => c.name).toList();
      if (columns.length > limits.maxColumns) {
        throw const BranchException('Column budget exceeded');
      }
      final keyColumns = parsed.columns.where((c) => c.primaryKey > 0).toList()
        ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
      if (keyColumns.isEmpty) {
        throw const BranchException(
            'Every table requires an explicit primary key');
      }
      final collations = parsed.primaryKeyCollations;
      if (keyColumns.any((c) => c.collation.toLowerCase() != 'binary') ||
          collations.any((c) => c.toLowerCase() != 'binary')) {
        throw const BranchException('Primary keys require BINARY collation');
      }
      final types = keyColumns
          .map((c) => c.declaredType.toUpperCase().contains('INT')
              ? 'integer'
              : c.affinity)
          .toList();
      if (types.any((t) => !['integer', 'text', 'blob'].contains(t))) {
        throw const BranchException(
            'Primary keys require INTEGER, TEXT or BLOB affinity');
      }
      final table = _Table(
          name, columns, keyColumns.map((c) => c.name).toList(), types, {});
      final values = await db.query(
          'SELECT ${columns.map(_quote).join(',')} FROM ${_quote(name)}');
      for (final valuesRow in values.rows) {
        if (++rowCount > limits.maxRows) {
          throw const BranchException('Row budget exceeded');
        }
        final row = {
          for (var i = 0; i < columns.length; i++) columns[i]: valuesRow[i]
        };
        for (var i = 0; i < table.keys.length; i++) {
          final value = row[table.keys[i]], type = types[i];
          if (!(type == 'integer' && value is BigInt ||
              type == 'text' && value is String ||
              type == 'blob' && value is Uint8List)) {
            throw const BranchException(
                'NULL or affinity-mismatched primary key');
          }
        }
        final id = table.identity(row);
        if (table.rows.containsKey(id)) {
          throw const BranchException('Duplicate row identity');
        }
        for (final value in row.values) {
          _wire(value);
        }
        table.rows[id] = row;
      }
      tables[name] = table;
    }
    final pragmas = <Object?>[];
    for (final name in ['user_version', 'application_id', 'encoding']) {
      final value = (await db.query('PRAGMA $name')).rows.single.single;
      pragmas.add(_wire(value));
    }
    return _Snapshot(jsonEncode([schema, pragmas]), tables);
  } finally {
    await db.close();
  }
}

List<BranchRowDiff> _diff(_Snapshot base, _Snapshot branch) {
  if (base.schema != branch.schema) {
    throw const BranchException('Schema changed; migrate outside branch v1');
  }
  final result = <BranchRowDiff>[];
  for (final table in base.tables.values) {
    final target = branch.tables[table.name]!;
    final ids = {...table.rows.keys, ...target.rows.keys}.toList()..sort();
    for (final id in ids) {
      final before = table.rows[id], after = target.rows[id];
      if (!_sameRow(before, after)) {
        result.add(BranchRowDiff._(
            table.name, table.key(before ?? after!), before, after));
      }
    }
  }
  return result;
}

List<BranchConflict> _conflicts(
    List<BranchRowDiff> changes, _Snapshot base, _Snapshot main) {
  if (base.schema != main.schema) {
    throw const BranchException('Main schema diverged from branch base');
  }
  final result = <BranchConflict>[];
  for (final change in changes) {
    final table = main.tables[change.table]!;
    final current = table.rows[table.identity(change._key)];
    void conflict(String kind, String? column) {
      final id = _hash(utf8.encode(jsonEncode(
          [change.table, table.identity(change._key), column, kind])));
      result.add(BranchConflict._(id, kind, column, change, current));
    }

    if (change._before == null) {
      if (current != null && !_sameRow(current, change._after)) {
        conflict('insert-insert', null);
      }
    } else if (change._after == null) {
      if (current != null && !_sameRow(current, change._before)) {
        conflict('delete-update', null);
      }
    } else if (current == null) {
      conflict('update-delete', null);
    } else {
      for (final column in change.changedColumns) {
        if (!_same(current[column], change._before[column]) &&
            !_same(current[column], change._after[column])) {
          conflict('update-update', column);
        }
      }
    }
  }
  return result;
}
