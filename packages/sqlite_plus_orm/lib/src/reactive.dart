part of '../sqlite_plus_orm.dart';

extension _ReactiveContext on DbContext {
  ReactiveRegistry _registry() => _reactiveRegistry ??= ReactiveRegistry(
      source: connection.changeFeed == null
          ? null
          : ChangesReactiveSource(connection.changeFeed!),
      debounce: reactiveDebounce,
      maxRows: reactiveMaxRows);

  Future<R> _runMigration<R>(Future<R> Function() action) => _run(() async {
        final result = await connection.exclusive(action, schemaChange: true);
        _reactiveRegistry?.invalidate(ReactiveInvalidation(all: true));
        return result;
      });

  Future<void> _ensureCapture() async {
    final feed = connection.changeFeed;
    if (feed == null) return;
    final sources = {
      for (final source in await feed.sources()) source.table: source
    };
    for (final type in model.entities) {
      if (type.virtualModule != null) continue;
      final source = sources[type.tableName];
      final keys = type.keys.map((c) => c.sqlName).toList();
      final columns = type.columns.map((c) => c.sqlName).toList();
      if (source == null) {
        if (_captureInitialized) {
          throw OrmStateException(
              'Reactive capture removed for ${type.tableName}; explicitly restore tracking');
        }
        await feed.track(
            table: type.tableName, primaryKey: keys, columns: columns);
      } else if (jsonEncode(source.primaryKey) != jsonEncode(keys) ||
          !columns.every(source.columns.contains)) {
        throw OrmStateException(
            'Changes must cover all mapped keys/columns for ${type.tableName}');
      }
    }
    _captureInitialized = true;
  }

  ReactiveQuery<T> _watch<T>(TypedQuery<T> query) {
    _checkUsable();
    if (query.type.scalars.any((s) => !s.deterministic)) {
      throw const OrmStateException(
          'Watch requires deterministic registered scalars');
    }
    final command = query.toSql();
    return _registry().watch(
        sql: command.sql,
        parameters: command.parameters,
        shareScope: query.type,
        keyColumns: query.type.keys.map((k) => k.sqlName).toList(),
        dependencies: {
          query.type.virtualModule != null ? '*' : query.type.tableName:
              query.type.virtualModule != null
                  ? null
                  : {
                      ...query.type.columns.map((c) => c.sqlName),
                      ...?query._predicate?._columns.map((c) => c.sqlName),
                      for (final term in query._ordering)
                        ...term.expression._columns.map((c) => c.sqlName),
                    }
        },
        evaluate: () => _run(() async {
              await _ensureCapture();
              registerOrmScalars(connection, [query.type]);
              return connection.query(command.sql, command.parameters);
            }),
        decode: (row) {
          final entity = query.type.create(RowReader(_copyOrmRow(row)));
          if (_entries.containsKey(entity)) {
            throw const OrmMappingException(
                'Reactive factory reused a tracked entity');
          }
          return entity;
        });
  }

  Stream<BigInt> _watchCount<T>(TypedQuery<T> query) {
    _checkUsable();
    if (query.type.scalars.any((s) => !s.deterministic)) {
      throw const OrmStateException(
          'Watch requires deterministic registered scalars');
    }
    final command = query.toSql();
    final sql =
        'SELECT COUNT(*) AS "_reactive_count" FROM (${command.sql}) AS "_orm_count"';
    return _registry()
        .watch<BigInt>(
            sql: sql,
            parameters: command.parameters,
            shareScope: query.type,
            dependencies: {
              query.type.virtualModule != null ? '*' : query.type.tableName:
                  query.type.virtualModule != null
                      ? null
                      : {...?query._predicate?._columns.map((c) => c.sqlName)}
            },
            evaluate: () => _run(() async {
                  await _ensureCapture();
                  registerOrmScalars(connection, [query.type]);
                  return connection.query(sql, command.parameters);
                }),
            decode: (row) {
              final value = row['_reactive_count'];
              if (value is! BigInt) {
                throw const OrmMappingException('COUNT returned a non-integer');
              }
              return value;
            })
        .map((s) => s.items.single);
  }

  void _notifySaved(
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Set<String> triggers) {
    final registry = _reactiveRegistry;
    if (registry == null || registry.activeQueryCount == 0) return;
    // Captured source batches supply exact invalidations. Still notify here:
    // virtual/untracked tables and trigger/FK side effects need conservative
    // coverage, and non-Changes connections have no external signal source.
    if (connection.changeFeed != null &&
        _captureInitialized &&
        [...batch.writes, ...batch.deletes]
            .every((p) => p.entry.type.virtualModule == null)) {
      return;
    }
    if (triggers.isNotEmpty || model.foreignKeys.isNotEmpty) {
      registry.invalidate(ReactiveInvalidation(all: true));
      return;
    }
    final tables = <String, Set<String>?>{};
    final structural = <String>{};
    for (final plan in [...batch.writes, ...batch.deletes]) {
      final type = plan.entry.type;
      if (plan.state == EntityState.added ||
          plan.state == EntityState.deleted) {
        structural.add(type.tableName);
      }
      final columns = tables.putIfAbsent(type.tableName, () => <String>{})!;
      final row = stored[plan.entry];
      for (final c in type.columns) {
        if (plan.state != EntityState.modified ||
            row == null ||
            !ormValuesEqual(plan.original[c.sqlName], row[c.sqlName])) {
          columns.add(c.sqlName);
        }
      }
    }
    registry.invalidate(
        ReactiveInvalidation(tables: tables, structural: structural));
  }
}

extension ReactiveDbContext on DbContext {
  /// Optional eager capture setup; watch also initializes it lazily.
  Future<void> enableReactive() => _run(() async {
        await _ensureCapture();
        _registry();
      });

  /// Explicit catch-up, including queued commit hints. No persistent consumer.
  Future<void> flushReactive() async {
    _checkUsable();
    await _reactiveRegistry?.flush();
  }

  int get activeReactiveQueryCount => _reactiveRegistry?.activeQueryCount ?? 0;
}
