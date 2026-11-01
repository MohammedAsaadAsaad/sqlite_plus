part of 'image_mutations.dart';

/// Full-image maintenance shares the same validation and atomic commit boundary
/// as ordinary mutations. Statistics describe actual supported index records;
/// they are not fabricated planner costs or STAT4 samples.
extension _ImageMaintenance on ImageMutations {
  MutationImage _vacuum(SqlParser parser, List<Object?> parameters,
      {required bool inTransaction}) {
    String? schema;
    if (parser.current.kind == SqlTokenKind.identifier &&
        parser.current.keyword != 'INTO') {
      schema = parser.identifier();
    }
    // The temporary database is parsed and then skipped, including `INTO`.
    if (schema != null && asciiLower(schema) == 'temp') {
      if (parser.take('INTO')) parser.expression();
      parser.finish();
      return MutationImage(original, 0, null);
    }
    if (inTransaction || _triggerContexts.isNotEmpty) {
      throw const SqlException('cannot VACUUM from within a transaction');
    }
    if (schema != null &&
        parser.current.keyword != 'INTO' &&
        asciiLower(schema) != 'main') {
      throw SqlException('Unknown database: $schema');
    }
    String? intoPath;
    if (parser.take('INTO')) {
      final value = _vacuumFilename(parser, parameters);
      if (value is! String) {
        throw const SqlException('non-text filename');
      }
      intoPath = value;
    } else if (parameters.isNotEmpty) {
      throw const SqlException('VACUUM bindings unsupported');
    }
    parser.finish();
    if (intoPath != null) return _vacuumInto(intoPath);
    final renumbered = _compactVacuumRowids();
    if (!renumbered && DatabaseHeader.decode(original).freelistPages == 0) {
      // The live rows already are the compact database. Rebuilding the byte
      // image here duplicated the work a later read performs.
      return MutationImage(original, 0, null);
    }
    schemaChanged = true;
    wroteRows = renumbered;
    return MutationImage(serialize(rowConstraints: false), 0, null);
  }

  Object? _vacuumFilename(SqlParser parser, List<Object?> parameters) {
    final expr = parser.expression();
    try {
      return resolveSqlValue(expr.evaluate(EvalContext(
          const <String, Object?>{}, const <String, String>{}, parameters)));
    } on RangeError {
      return null;
    }
  }

  /// Builds a compact copy without keeping the renumbered source rows.
  MutationImage _vacuumInto(String path) {
    final savedRows = <_Table, List<TableRow>>{
      for (final table in _tables.values) table: table.rows.toList(),
    };
    final savedAddends = <_Table, Map<int, BigInt>?>{
      for (final table in _tables.values)
        table: table.columnAddends == null
            ? null
            : Map<int, BigInt>.of(table.columnAddends!),
    };
    final savedSchema = schemaChanged;
    final savedWrote = wroteRows;
    try {
      _compactVacuumRowids();
      schemaChanged = true;
      final bytes = serialize(rowConstraints: false);
      return MutationImage(original, 0, null, null, VacuumInto(path, bytes));
    } finally {
      for (final entry in savedRows.entries) {
        entry.key.rows
          ..clear()
          ..addAll(entry.value);
        final addends = savedAddends[entry.key];
        entry.key.columnAddends =
            addends == null ? null : Map<int, BigInt>.of(addends);
        entry.key.invalidateResidentKeys();
      }
      schemaChanged = savedSchema;
      wroteRows = savedWrote;
    }
  }

  bool _compactVacuumRowids() {
    var renumbered = false;
    for (final table in _tables.values) {
      if (table.schema.withoutRowid ||
          table.schema.rowidAlias != null ||
          _indexes.any((index) =>
              asciiLower(index.table) == asciiLower(table.schema.name))) {
        continue;
      }
      // Like the reference, a table without a rowid alias or secondary index
      // can receive compact rowids during VACUUM. Indexed rowids stay stable.
      final rows = table.rows.toList()
        ..sort((a, b) => a.rowId.compareTo(b.rowId));
      var changed = false;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].rowId != BigInt.from(i + 1)) {
          changed = true;
          break;
        }
      }
      if (!changed) continue;
      renumbered = true;
      table.rows
        ..clear()
        ..addAll([
          for (var i = 0; i < rows.length; i++)
            TableRow(BigInt.from(i + 1), rows[i].values)
        ]);
      table.invalidateResidentKeys();
    }
    return renumbered;
  }

  MutationImage _maintenance(SqlParser parser, List<Object?> parameters,
      {required bool analyze}) {
    String? name;
    var qualified = false;
    if (parser.current.kind != SqlTokenKind.end && parser.current.text != ';') {
      name = parser.identifier();
      if (parser.take('.')) {
        if (asciiLower(name) != 'main') {
          throw SqlException('Unknown database: $name');
        }
        qualified = true;
        name = parser.identifier();
      }
    }
    parser.finish();
    if (parameters.isNotEmpty) {
      throw const SqlException('Maintenance statements take no parameters');
    }
    final key = name == null ? null : asciiLower(name);
    final all = key == null || analyze && !qualified && key == 'main';
    final schema = ['sqlite_schema', 'sqlite_master'].contains(key);
    final table = _tables[key];
    final index =
        _indexes.where((index) => asciiLower(index.name) == key).firstOrNull;
    final view = other.any(
        (object) => object.type == 'view' && asciiLower(object.name) == key);
    final collation =
        !qualified && !analyze && ['binary', 'nocase', 'rtrim'].contains(key);
    if (!all &&
        !schema &&
        table == null &&
        index == null &&
        !view &&
        !collation) {
      throw SqlException(analyze
          ? 'No such table: $name'
          : 'Unable to identify the object to be reindexed: $name');
    }
    if (analyze) {
      var statistics = _tables['sqlite_stat1'];
      if (statistics == null) {
        const sql = 'CREATE TABLE sqlite_stat1(tbl,idx,stat)';
        statistics = _Table(DatabaseCatalog.parseTable(sql, 0), sql, []);
        _tables['sqlite_stat1'] = statistics;
        schemaChanged = true;
      }
      if (all) {
        statistics.rows.clear();
      } else if (index != null) {
        _removeStatistics(index: index.name);
      } else if (table != null && !key.startsWith('sqlite_')) {
        _removeStatistics(table: table.schema.name);
      }
      for (final target in _tables.values.toList()) {
        if (asciiLower(target.schema.name).startsWith('sqlite_') ||
            !all &&
                !identical(target, table) &&
                (index == null ||
                    asciiLower(index.table) !=
                        asciiLower(target.schema.name))) {
          continue;
        }
        final indexes = _indexes
            .where((candidate) =>
                asciiLower(candidate.table) == asciiLower(target.schema.name) &&
                (index == null || identical(index, candidate)))
            .toList();
        if (target.schema.withoutRowid && index == null) {
          final primary = target.schema.columns
              .where((column) => column.primaryKey != 0)
              .toList()
            ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
          indexes.insert(
              0,
              _Index(
                  target.schema.name,
                  target.schema.name,
                  primary.map((column) => column.name).toList(),
                  target.schema.primaryKeyDescending,
                  target.schema.primaryKeyCollations,
                  true,
                  null));
        }
        // SQLite visits the most recently declared secondary index first.
        for (final candidate in indexes.reversed) {
          if (target.rows.isEmpty && candidate.definition?.predicate == null) {
            continue;
          }
          final keys = [
            for (final row in target.rows)
              if (_includes(candidate, target, row))
                _indexKey(candidate, target, row)
          ]..sort((a, b) => _compare(candidate, a, b));
          final distinct = List.filled(candidate.columns.length, 0);
          for (var row = 0; row < keys.length; row++) {
            var changed = row == 0;
            for (var column = 0; column < distinct.length; column++) {
              if (!changed) {
                changed = compareValues(
                        keys[row - 1][column],
                        keys[row][column],
                        encoding,
                        candidate.collations[column]) !=
                    0;
              }
              if (changed) distinct[column]++;
            }
          }
          _appendStatistics(statistics, target.schema.name, candidate.name, [
            keys.length,
            for (final count in distinct)
              count == 0 ? 0 : (keys.length + count - 1) ~/ count
          ]);
        }
        if (index == null &&
            target.rows.isNotEmpty &&
            !indexes
                .any((candidate) => candidate.definition?.predicate == null)) {
          _appendStatistics(
              statistics, target.schema.name, null, [target.rows.length]);
        }
      }
    }
    // Serialization validates uniqueness, regenerates expression/partial index
    // records, and rebuilds every physical index using the current definitions.
    return MutationImage(serialize(rowConstraints: false), 0, null);
  }

  void _appendStatistics(
      _Table table, String target, String? index, List<int> counts) {
    final largest = table.rows.fold<BigInt>(
        BigInt.zero, (value, row) => row.rowId > value ? row.rowId : value);
    table.rows.add(TableRow(largest + BigInt.one,
        [target, index, counts.map((count) => '$count').join(' ')]));
  }

  void _removeStatistics({String? table, String? index}) {
    _tables['sqlite_stat1']?.rows.removeWhere((row) =>
        table != null && row.values[0] == table ||
        index != null && row.values[1] == index);
  }
}
