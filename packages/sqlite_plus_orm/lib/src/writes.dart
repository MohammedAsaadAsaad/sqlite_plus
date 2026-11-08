part of '../sqlite_plus_orm.dart';

/// SQL storage values after the operation (and its triggers), never tracked entities.
final class OrmWriteResult {
  OrmWriteResult._(this.affectedRows, Iterable<Map<String, Object?>> rows)
      : _rows = List.unmodifiable(rows.map(_copyOrmRow));
  final int affectedRows;
  final List<Map<String, Object?>> _rows;
  List<Map<String, Object?>> get rows => List.unmodifiable(
      _rows.map((r) => Map<String, Object?>.unmodifiable(_copyOrmRow(r))));
}

final class _ArithmeticAssignment<T, V> extends SqlExpression<T, V> {
  _ArithmeticAssignment(this.column, this.operator, V value)
      : value = column.encodeValue(value) {
    if (!['INTEGER', 'REAL'].contains(column.codec.sqlType) ||
        this.value == null) {
      throw const OrmMappingException(
          'Arithmetic assignments require a numeric column and non-null value');
    }
  }
  final Column<T, V> column;
  final String operator;
  final Object? value;
  @override
  Iterable<Column<T, dynamic>> get _columns => [column];
  @override
  String _sql(List<Object?> parameters) {
    parameters.add(copyOrmValue(value));
    return '(${quoteIdentifier(column.sqlName)} $operator ?)';
  }

  @override
  Object? _encodeComparison(Object? value) => column.encodeValue(value as V);
}

extension NumericColumnWrites<T, V> on Column<T, V> {
  SqlExpression<T, V> add(V value) => _ArithmeticAssignment(this, '+', value);
  SqlExpression<T, V> subtract(V value) =>
      _ArithmeticAssignment(this, '-', value);
}

DbContext _directOwner<T>(TypedQuery<T> query) {
  final owner = query._context ??
      (query.connection._owner is DbContext
          ? query.connection._owner as DbContext
          : null);
  if (owner == null ||
      !identical(owner.connection, query.connection) ||
      !owner.model.entities.contains(query.type)) {
    throw const OrmStateException(
        'Direct writes require an owning DbContext/DbSet');
  }
  return owner;
}

void _writeColumns<T>(
    EntityType<T> type, Iterable<Column<T, dynamic>> columns) {
  if (columns.any((c) => !type.columns.contains(c))) {
    throw const OrmMappingException('Write column belongs to another mapping');
  }
}

void _writeType(EntityType<dynamic> type) {
  if (type.virtualModule != null) {
    throw const OrmMappingException(
        'Direct writes currently require ordinary mapped tables');
  }
}

List<Column<T, dynamic>> _projection<T>(
    EntityType<T> type, List<Column<T, dynamic>> columns) {
  _writeColumns(type, columns);
  if (columns.toSet().length != columns.length) {
    throw const OrmMappingException('Duplicate returning column');
  }
  return List.unmodifiable(columns);
}

extension DirectQueryWrites<T> on TypedQuery<T> {
  /// Immediate atomic UPDATE; skip/take/order/rank windows are rejected.
  Future<OrmWriteResult> update(Map<Column<T, dynamic>, Object?> values,
      {List<Column<T, dynamic>> returning = const []}) {
    try {
      final owner = _directOwner(this);
      _writeType(type);
      if (_offset != 0 ||
          _limit != null ||
          _ordering.isNotEmpty ||
          _rank ||
          _distance) {
        throw const OrmStateException(
            'Direct UPDATE cannot combine with ordering, skip/take, rank or distance');
      }
      if (values.isEmpty) {
        throw const OrmMappingException(
            'UPDATE requires at least one assignment');
      }
      _writeColumns(type, values.keys);
      final selected = _projection(type, returning);
      final parameters = <Object?>[];
      final assignments = <String>[];
      final changed = <Column<T, dynamic>>[];
      for (final assignment in values.entries) {
        final column = assignment.key;
        if (column.keyOrder != null || column.generated || column.version) {
          throw const OrmMappingException(
              'Keys, generated fields and versions are managed by ORM');
        }
        final value = assignment.value;
        String expression;
        if (value is _ArithmeticAssignment<T, dynamic>) {
          if (!['INTEGER', 'REAL'].contains(column.codec.sqlType)) {
            throw const OrmMappingException(
                'Arithmetic assignment requires a numeric target');
          }
          _writeColumns(type, value._columns);
          expression = value._sql(parameters);
        } else {
          if (value is SqlExpression) {
            throw const OrmMappingException(
                'Only constants and add/subtract assignments are supported');
          }
          parameters.add(copyOrmValue(column.encodeValue(value)));
          expression = '?';
        }
        assignments.add('${quoteIdentifier(column.sqlName)}=$expression');
        changed.add(column);
      }
      final version = type.versionColumn;
      if (version != null) {
        assignments.add(
            '${quoteIdentifier(version.sqlName)}=${quoteIdentifier(version.sqlName)}+1');
        changed.add(version);
      }
      final predicate = _predicate?._sql(parameters);
      final sql =
          'UPDATE ${quoteIdentifier(type.tableName)} SET ${assignments.join(',')}${predicate == null ? '' : ' WHERE $predicate'}';
      final bound = List<Object?>.unmodifiable(parameters.map(copyOrmValue));
      return owner._directWrite(() async {
        final broad = (await owner._triggerTables())
                .contains(type.tableName.toLowerCase()) ||
            owner.model.foreignKeys.isNotEmpty;
        final projected = <Column<T, dynamic>>{
          ...changed,
          ...selected,
          if (broad) ...type.keys
        }.toList();
        final mutation = await owner.connection.execute(
            '$sql RETURNING ${projected.map((c) => quoteIdentifier(c.sqlName)).join(',')}',
            bound);
        final rows = await owner._writeRows(type, mutation, projected, selected,
            broad: broad);
        return OrmWriteResult._(mutation.changes, rows);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}

extension DirectSetWrites<T> on DbSet<T> {
  Future<OrmWriteResult> upsert(T entity,
          {required List<Column<T, dynamic>> conflictOn,
          required List<Column<T, dynamic>> update,
          List<Column<T, dynamic>>? returning}) =>
      upsertMany([entity],
          conflictOn: conflictOn, update: update, returning: returning);

  /// Input is snapshotted now. All chunks commit or roll back together.
  Future<OrmWriteResult> upsertMany(Iterable<T> entities,
      {required List<Column<T, dynamic>> conflictOn,
      required List<Column<T, dynamic>> update,
      List<Column<T, dynamic>>? returning,
      int batchSize = 200}) {
    try {
      _writeType(type);
      if (batchSize < 1 || batchSize > 1000) {
        throw RangeError.range(batchSize, 1, 1000, 'batchSize');
      }
      final keys = _projection(type, conflictOn),
          fields = _projection(type, update);
      final selected = _projection(type, returning ?? type.columns);
      if (keys.isEmpty || fields.isEmpty) {
        throw const OrmMappingException(
            'Upsert requires conflict and update columns');
      }
      if (fields.any((c) =>
          c.keyOrder != null || c.generated || c.version || keys.contains(c))) {
        throw const OrmMappingException(
            'Upsert cannot update keys, conflict columns, generated fields or managed versions');
      }
      final input = <Map<String, Object?>>[];
      for (final entity in entities) {
        if (input.length == 10000) {
          throw RangeError('At most 10000 upsert inputs per call');
        }
        final row = _copyOrmRow(type.encode(entity));
        if (keys.any((c) => row[c.sqlName] == null)) {
          throw const OrmMappingException(
              'Upsert conflict values cannot be NULL');
        }
        input.add(row);
      }
      if (input.length * keys.length > 20000) {
        throw RangeError('Upsert conflict validation exceeds 20000 parameters');
      }
      return context._directWrite(() async {
        final collations = await context._uniqueTarget(type, keys);
        if (input.isEmpty) return OrmWriteResult._(0, []);
        if (input.length > 1) {
          final args = <Object?>[];
          final values = [
            for (final row in input)
              '(${keys.map((c) {
                args.add(copyOrmValue(row[c.sqlName]));
                return '?';
              }).join(',')})'
          ];
          final aliases = [
            for (var i = 0; i < keys.length; i++) quoteIdentifier('_key$i')
          ];
          final group = [
            for (var i = 0; i < keys.length; i++)
              '${aliases[i]} COLLATE ${quoteIdentifier(collations[i])}'
          ];
          final duplicate = await context.connection.query(
              'WITH ${quoteIdentifier('_orm_input')} (${aliases.join(',')}) AS (VALUES ${values.join(',')}) SELECT 1 FROM ${quoteIdentifier('_orm_input')} GROUP BY ${group.join(',')} HAVING COUNT(*)>1 LIMIT 1',
              args);
          if (duplicate.rows.isNotEmpty) {
            throw const OrmStateException(
                'Duplicate conflict keys inside upsert batch');
          }
        }
        final broad = (await context._triggerTables())
                .contains(type.tableName.toLowerCase()) ||
            context.model.foreignKeys.isNotEmpty;
        final projected = <Column<T, dynamic>>{
          ...type.keys,
          ...fields,
          ...selected,
          if (type.versionColumn != null) type.versionColumn!
        }.toList();
        final target = [
          for (var i = 0; i < keys.length; i++)
            '${quoteIdentifier(keys[i].sqlName)} COLLATE ${quoteIdentifier(collations[i])}'
        ].join(',');
        final sets = [
          for (final c in fields)
            '${quoteIdentifier(c.sqlName)}=excluded.${quoteIdentifier(c.sqlName)}',
          if (type.versionColumn != null)
            '${quoteIdentifier(type.versionColumn!.sqlName)}=${quoteIdentifier(type.versionColumn!.sqlName)}+1'
        ];
        final result = <Map<String, Object?>>[];
        final targetKeys = <Map<String, Object?>>[];
        var affected = 0, index = 0;
        while (index < input.length) {
          final columns = context._insertColumns(type, input[index]);
          final args = <Object?>[];
          final values = <String>[];
          while (index < input.length &&
              values.length < batchSize &&
              (values.length + 1) * columns.length <= 20000) {
            final row = input[index];
            final next = context._insertColumns(type, row);
            if (next.length != columns.length ||
                !List.generate(
                        columns.length, (i) => identical(columns[i], next[i]))
                    .every((v) => v)) {
              break;
            }
            values.add('(${columns.map((c) {
              args.add(copyOrmValue(row[c.sqlName]));
              return '?';
            }).join(',')})');
            index++;
          }
          if (values.isEmpty) {
            throw const OrmMappingException(
                'Upsert row exceeds parameter budget');
          }
          final sql =
              'INSERT INTO ${quoteIdentifier(type.tableName)} (${columns.map((c) => quoteIdentifier(c.sqlName)).join(',')}) VALUES ${values.join(',')} ON CONFLICT ($target) DO UPDATE SET ${sets.join(',')} RETURNING ${projected.map((c) => quoteIdentifier(c.sqlName)).join(',')}';
          if (sql.length > 900000) {
            throw RangeError('Upsert SQL exceeds statement budget');
          }
          final mutation = await context.connection.execute(sql, args);
          affected += mutation.changes;
          result.addAll(await context
              ._writeRows(type, mutation, projected, selected, broad: false));
          if (broad) {
            final returned = mutation.returning!;
            for (final raw in returned.rows) {
              final reader = context._reader(returned, raw);
              targetKeys.add({
                for (final key in type.keys)
                  key.sqlName: reader.raw(key.sqlName)
              });
            }
          }
        }
        if (broad) {
          result.clear();
          for (final key in targetKeys) {
            final row = await context._readStored(type, key);
            if (row == null) {
              throw const OrmStateException(
                  'A trigger removed an upsert target or changed its key');
            }
            if (selected.isNotEmpty) {
              result.add({
                for (final column in selected)
                  column.sqlName: copyOrmValue(row[column.sqlName])
              });
            }
          }
        }
        return OrmWriteResult._(affected, result);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}

extension _DirectWriteContext on DbContext {
  Future<List<String>> _uniqueTarget<T>(
      EntityType<T> type, List<Column<T, dynamic>> keys) async {
    final names = keys.map((c) => _ormAsciiLower(c.sqlName)).toList();
    final matches = <List<String>>[];
    final info = await connection
        .query('SELECT * FROM pragma_table_info(?)', [type.tableName]);
    final primary = info.rows
        .where((r) => r[5] is BigInt && (r[5] as BigInt) > BigInt.zero)
        .toList();
    if (names.length == 1 &&
        primary.length == 1 &&
        _ormAsciiLower(primary.single[1] as String) == names.single &&
        (primary.single[2] as String).toUpperCase() == 'INTEGER') {
      matches.add(['BINARY']);
    }
    final indexes = await connection
        .query('SELECT * FROM pragma_index_list(?)', [type.tableName]);
    for (final index in indexes.rows) {
      if (index[2] != BigInt.one || index[4] != BigInt.zero) continue;
      final xinfo = await connection
          .query('SELECT * FROM pragma_index_xinfo(?)', [index[1]]);
      final terms = xinfo.rows.where((r) => r[5] == BigInt.one).toList();
      if (terms.length != names.length || terms.any((r) => r[2] is! String)) {
        continue;
      }
      final actual = terms.map((r) => _ormAsciiLower(r[2] as String)).toList();
      if (names.every(actual.contains)) {
        matches.add(
            [for (final n in names) terms[actual.indexOf(n)][4] as String]);
      }
    }
    if (matches.isEmpty) {
      throw const OrmMappingException(
          'Upsert target must match an ordinary UNIQUE/PRIMARY KEY constraint');
    }
    final first = matches.first.map(_ormAsciiLower).toList();
    if (matches.any((m) =>
        jsonEncode(m.map(_ormAsciiLower).toList()) != jsonEncode(first))) {
      throw const OrmMappingException(
          'Upsert target has ambiguous unique collations');
    }
    return matches.first;
  }

  Future<List<Map<String, Object?>>> _writeRows<T>(
      EntityType<T> type,
      MutationResult mutation,
      List<Column<T, dynamic>> projected,
      List<Column<T, dynamic>> selected,
      {required bool broad}) async {
    final result = mutation.returning;
    if (result == null || result.rows.length != mutation.changes) {
      throw const OrmStateException('Direct write returned inconsistent rows');
    }
    final rows = <Map<String, Object?>>[];
    for (final raw in result.rows) {
      final reader = _reader(result, raw);
      final values = {
        for (final c in projected)
          c.sqlName: c.encodeValue(c.decodeValue(reader.raw(c.sqlName)))
      };
      Map<String, Object?> actual = values;
      if (broad) {
        final stored = await _readStored(type, values);
        if (stored == null) {
          throw const OrmStateException(
              'A trigger removed a target row or changed its primary key');
        }
        actual = stored;
      }
      if (selected.isNotEmpty) {
        rows.add({
          for (final c in selected) c.sqlName: copyOrmValue(actual[c.sqlName])
        });
      }
    }
    return rows;
  }

  Future<OrmWriteResult> _directWrite(
      Future<OrmWriteResult> Function() action) {
    try {
      _checkTrackingMutable();
      _savePending = true;
      return _run(() async {
        final frozen = _freeze();
        if (frozen.writes.isNotEmpty || frozen.deletes.isNotEmpty) {
          throw const OrmStateException(
              'Save or discard pending tracked changes before direct writes');
        }
        if (connection.inTransaction) {
          throw const OrmStateException(
              'Direct writes cannot join an external transaction');
        }
        await _ensureCapture();
        final stored = <EntityEntry<dynamic>, Map<String, Object?>?>{};
        late OrmWriteResult result;
        Future<void> write() async {
          result = await action();
          for (final entry in frozen.tracked) {
            final row =
                await _readStored(entry.type, frozen.frozenValues[entry]!);
            if (row != null) entry.type.create(RowReader(row));
            stored[entry] = row;
            _checkKey(entry, entry.type.encode(entry.entity));
          }
        }

        var began = false, committing = false;
        try {
          began = true;
          if (connection.usesSaveTransactionDriver) {
            await connection.transaction(write,
                onCommitting: () => committing = true);
          } else {
            await connection.execute('BEGIN');
            await write();
            committing = true;
            await connection.execute('COMMIT');
          }
          began = false;
          committing = false;
        } catch (error, stack) {
          Object? cleanup;
          if (began) {
            try {
              if (connection.inTransaction) {
                await connection.execute('ROLLBACK');
              }
            } catch (e) {
              cleanup = e;
            }
          }
          if (cleanup != null ||
              committing && error is! SqlConstraintException) {
            _poisoned = true;
          }
          if (cleanup != null) {
            Error.throwWithStackTrace(
                OrmStateException(
                    'Direct write failed and rollback also failed',
                    (operation: error, rollback: cleanup)),
                stack);
          }
          Error.throwWithStackTrace(error, stack);
        }
        try {
          for (final entry in frozen.tracked) {
            final row = stored[entry];
            _checkKey(entry, entry.type.encode(entry.entity));
            if (row == null) {
              _detach(entry);
            } else {
              _publish(entry, row, frozen.frozenValues[entry]!);
            }
          }
        } catch (error) {
          _poisoned = true;
          throw OrmStateException(
              'Direct write committed but applying store values failed', error);
        }
        // BEFORE triggers can write other rows and then IGNORE the target,
        // producing zero direct changes but still requiring a refresh.
        _reactiveRegistry?.invalidate(ReactiveInvalidation(all: true));
        return result;
      }).whenComplete(() => _savePending = false);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}
