part of '../sqlite_plus_orm.dart';

enum EntityState { added, unchanged, modified, deleted, detached }

Map<String, Object?> _copyOrmRow(Map<String, Object?> values) =>
    {for (final value in values.entries) value.key: copyOrmValue(value.value)};

bool _ormRowsEqual(Map<String, Object?> left, Map<String, Object?> right) =>
    left.length == right.length &&
    left.entries.every((entry) =>
        right.containsKey(entry.key) &&
        ormValuesEqual(entry.value, right[entry.key]));

EntityKey _ormRowKey(EntityType<dynamic> type, Map<String, Object?> values) {
  final key = [for (final column in type.keys) values[column.sqlName]];
  if (key.any((value) => value == null)) {
    throw const OrmStateException('An assigned primary key cannot be null');
  }
  return EntityKey(key);
}

final class EntityEntry<T> {
  EntityEntry._(this.context, this.type, this._entity, this._state,
      this._snapshot, this._identity);
  final DbContext context;
  final EntityType<T> type;
  T _entity;
  T get entity => _entity;
  EntityState _state;
  Map<String, Object?> _snapshot;
  EntityKey? _identity;

  EntityState get state {
    if (_state != EntityState.unchanged) return _state;
    final values = type.encode(entity);
    context._checkKey(this, values);
    if (!_ormRowsEqual(values, _snapshot) ||
        context._relationshipChanged(this, values)) {
      return EntityState.modified;
    }
    return EntityState.unchanged;
  }

  /// Encoded original values. BLOBs are copied on every access.
  Map<String, Object?> get originalValues =>
      Map.unmodifiable(_copyOrmRow(_snapshot));
}

final class DbSet<T> {
  DbSet._(this.context, this.type);
  final DbContext context;
  final EntityType<T> type;

  EntityEntry<T> add(T entity) => context._track(type, entity, true);
  EntityEntry<T> attach(T entity) => context._track(type, entity, false);

  void remove(T entity) {
    context._checkTrackingMutable();
    final tracked = context._entries[entity];
    final entry = tracked == null ? attach(entity) : tracked as EntityEntry<T>;
    if (!identical(entry.type, type)) {
      throw const OrmStateException('Entity belongs to another mapping');
    }
    if (entry._state == EntityState.added) {
      context._detach(entry);
    } else if (entry._state != EntityState.detached) {
      entry._state = EntityState.deleted;
    }
  }

  EntityEntry<T> replace(T previous, T replacement) {
    context._checkTrackingMutable();
    final entry = context.entry(previous);
    if (!identical(entry.type, type) || entry._state == EntityState.deleted) {
      throw const OrmStateException('Cannot replace this tracked entity');
    }
    final values = type.encode(replacement);
    context._checkKey(entry, values);
    final other = context._entries[replacement];
    if (other != null && !identical(other, entry)) {
      throw const OrmStateException('Replacement is already tracked');
    }
    context._entries.remove(previous);
    entry._entity = replacement;
    context._entries[replacement as Object] = entry;
    return entry;
  }

  TypedQuery<T> get query => TypedQuery<T>(
      type: type,
      connection: context.connection,
      materialize: (row) => context._materialize(type, row),
      serialize: context._run);

  Future<T?> find(EntityKey key) => context._run(() async {
        final values = key.values;
        if (values.length != type.keys.length) {
          throw const OrmStateException('Primary key width does not match');
        }
        final normalized = [
          for (var i = 0; i < values.length; i++)
            type.keys[i].encodeValue(type.keys[i].decodeValue(values[i]))
        ];
        if (normalized.any((value) => value == null)) {
          throw const OrmStateException('Primary key cannot be null');
        }
        final identity = EntityKey(normalized);
        final known = context._identities[type]?[identity];
        if (known != null && known._state != EntityState.detached) {
          return known.entity as T;
        }
        final result = await context.connection.query(
            'SELECT ${context._columnList(type)} FROM '
            '${quoteIdentifier(type.tableName)} WHERE '
            '${type.keys.map((column) => '${quoteIdentifier(column.sqlName)} IS ?').join(' AND ')}',
            normalized);
        if (result.rows.isEmpty) return null;
        if (result.rows.length != 1) {
          throw const OrmStateException('Primary key selected multiple rows');
        }
        return context._materialize<T>(
            type, context._reader(result, result.rows[0]));
      });
}

final class _SaveIntent {
  _SaveIntent(this.entry, this.state, this.values, this.original, this.links,
      this.linkVersions);
  final EntityEntry<dynamic> entry;
  final EntityState state;
  final Map<String, Object?> values;
  final Map<String, Object?> original;
  final Map<ForeignKey<dynamic, dynamic>, EntityEntry<dynamic>?> links;
  final Map<ForeignKey<dynamic, dynamic>, int> linkVersions;
}

final class _SaveBatch {
  _SaveBatch(this.writes, this.deletes, this.tracked, this.frozenValues);
  final List<_SaveIntent> writes, deletes;
  final List<EntityEntry<dynamic>> tracked;
  final Map<EntityEntry<dynamic>, Map<String, Object?>> frozenValues;
}

/// One tracked unit of work with an exclusive connection and serialized SQL.
///
/// Entity properties may change while a save awaits: those later edits remain
/// dirty. A second save or synchronous add/attach/remove/replace during a pending
/// save is rejected; SQL query operations are queued instead.
final class DbContext {
  DbContext(this.connection, this.model) {
    connection.claim(this);
  }
  final OrmConnection connection;
  final DbModel model;
  final Map<Object, EntityEntry<dynamic>> _entries = Map.identity();
  final Map<EntityType<dynamic>, Map<EntityKey, EntityEntry<dynamic>>>
      _identities = {};
  final Map<EntityEntry<dynamic>,
          Map<ForeignKey<dynamic, dynamic>, EntityEntry<dynamic>?>>
      _relationshipLinks = {};
  final Map<EntityEntry<dynamic>,
          Map<ForeignKey<dynamic, dynamic>, List<Object?>>>
      _relationshipLinkValues = {};
  final Map<EntityEntry<dynamic>, Map<ForeignKey<dynamic, dynamic>, int>>
      _relationshipLinkVersions = {};
  int _linkVersion = 0;
  Future<void> _tail = Future.value();
  bool _initialized = false, _closed = false, _closing = false;
  bool _poisoned = false, _savePending = false;
  SchemaMigrator? _migrations;
  bool get _transactionFailed => _poisoned || _migrations?._failed == true;
  SchemaMigrator get migrations =>
      _migrations ??= SchemaMigrator(connection, model, serialize: _run);

  void _checkUsable() {
    if (_closed || _closing) {
      throw const OrmStateException('Context is closed');
    }
    if (_transactionFailed) {
      throw const OrmStateException(
          'Context has an indeterminate transaction outcome; reopen it');
    }
  }

  void _checkTrackingMutable() {
    _checkUsable();
    if (_savePending) {
      throw const OrmStateException(
          'Tracking membership cannot change during a pending save');
    }
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    if (connection.inTransaction) {
      throw const OrmStateException(
          'Context cannot adopt an external transaction');
    }
    await connection.execute('PRAGMA foreign_keys=ON');
    final enabled = await connection.query('PRAGMA foreign_keys');
    if (enabled.rows.length != 1 || enabled.rows.single.single != BigInt.one) {
      throw const OrmStateException('Foreign key enforcement is required');
    }
    _initialized = true;
  }

  Future<R> _run<R>(Future<R> Function() operation) {
    try {
      _checkUsable();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    final result = Completer<R>();
    _tail = _tail.then((_) async {
      try {
        if (_closed || _transactionFailed) {
          throw const OrmStateException('Context is not usable');
        }
        await _initialize();
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<R> _serialize<R>(Future<R> Function() operation) => _run(operation);

  DbSet<T> set<T>(EntityType<T> type) {
    _checkUsable();
    if (!model.entities.contains(type)) {
      throw const OrmMappingException('Entity mapping is not registered');
    }
    return DbSet._(this, type);
  }

  EntityEntry<T> entry<T>(T entity) {
    _checkUsable();
    final entry = _entries[entity];
    if (entry == null || entry._state == EntityState.detached) {
      throw const OrmStateException('Entity is not tracked');
    }
    return entry as EntityEntry<T>;
  }

  EntityEntry<T> _track<T>(EntityType<T> type, T entity, bool added) {
    _checkTrackingMutable();
    if (entity == null) throw const OrmStateException('Entity cannot be null');
    final previous = _entries[entity];
    if (previous != null) {
      if (!identical(previous.type, type) ||
          previous._state == EntityState.deleted ||
          added && previous._state != EntityState.added) {
        throw const OrmStateException('Entity is already tracked differently');
      }
      return previous as EntityEntry<T>;
    }
    final values = type.encode(entity);
    final generatedNull =
        type.generatedKey != null && values[type.generatedKey!.sqlName] == null;
    final identity = added && generatedNull ? null : _ormRowKey(type, values);
    if (identity != null && _identities[type]?.containsKey(identity) == true) {
      throw const OrmStateException('Another instance has this primary key');
    }
    final entry = EntityEntry<T>._(
        this,
        type,
        entity,
        added ? EntityState.added : EntityState.unchanged,
        added ? {} : _copyOrmRow(values),
        identity);
    _entries[entity as Object] = entry;
    if (identity != null) (_identities[type] ??= {})[identity] = entry;
    return entry;
  }

  void _checkKey(EntityEntry<dynamic> entry, Map<String, Object?> values) {
    if (entry._identity != null &&
        _ormRowKey(entry.type, values) != entry._identity) {
      throw const OrmStateException('Tracked primary keys cannot change');
    }
  }

  RowReader _reader(QueryResult result, List<Object?> row) => RowReader({
        for (var i = 0; i < result.columns.length; i++)
          result.columns[i]: row[i]
      });

  Map<String, Object?> _storedValues(EntityType<dynamic> type, RowReader row) =>
      {
        for (final column in type.columns)
          column.sqlName:
              column.encodeValue(column.decodeValue(row.raw(column.sqlName)))
      };

  T _materialize<T>(EntityType<T> type, RowReader row) {
    final values = _storedValues(type, row);
    final identity = _ormRowKey(type, values);
    final known = _identities[type]?[identity];
    if (known != null && known._state != EntityState.detached) {
      return known.entity as T;
    }
    final entity = type.create(RowReader(values));
    if (_entries.containsKey(entity)) {
      throw const OrmMappingException('Factory reused a tracked object');
    }
    final entry = EntityEntry<T>._(this, type, entity, EntityState.unchanged,
        _copyOrmRow(values), identity);
    _entries[entity as Object] = entry;
    (_identities[type] ??= {})[identity] = entry;
    return entity;
  }

  void _detach(EntityEntry<dynamic> entry) {
    _entries.remove(entry.entity);
    if (entry._identity != null) {
      _identities[entry.type]?.remove(entry._identity);
    }
    _relationshipLinks.remove(entry);
    _relationshipLinkValues.remove(entry);
    _relationshipLinkVersions.remove(entry);
    entry._state = EntityState.detached;
  }

  void _setRelationshipLink<C, P>(
      EntityEntry<C> child, ForeignKey<C, P> key, EntityEntry<P>? parent) {
    _checkUsable();
    if (!identical(child.context, this) ||
        !identical(child.type, key.child) ||
        !model.foreignKeys.contains(key) ||
        [EntityState.detached, EntityState.deleted].contains(child._state) ||
        parent != null &&
            (!identical(parent.context, this) ||
                !identical(parent.type, key.parent) ||
                [EntityState.detached, EntityState.deleted]
                    .contains(parent._state))) {
      throw const OrmStateException('Invalid tracked relationship link');
    }
    if (parent == null && key.columns.every((column) => !column.nullable)) {
      throw const OrmStateException('Required relationship cannot be cleared');
    }
    (_relationshipLinks[child] ??= {})[key] = parent;
    (_relationshipLinkValues[child] ??= {})[key] = [
      for (final column in key.columns) column.readEncoded(child.entity)
    ];
    (_relationshipLinkVersions[child] ??= {})[key] = ++_linkVersion;
  }

  void _validateRelationshipLinks(EntityEntry<dynamic> entry) {
    for (final link in (_relationshipLinks[entry] ?? {}).entries) {
      final original = _relationshipLinkValues[entry]![link.key]!;
      for (var i = 0; i < link.key.columns.length; i++) {
        if (!ormValuesEqual(
            original[i], link.key.columns[i].readEncoded(entry.entity))) {
          throw const OrmStateException(
              'Relationship link and foreign key properties disagree');
        }
      }
      if (link.value != null &&
          [EntityState.deleted, EntityState.detached]
              .contains(link.value!._state)) {
        throw const OrmStateException(
            'Relationship parent is no longer tracked');
      }
    }
  }

  bool _relationshipChanged(
      EntityEntry<dynamic> entry, Map<String, Object?> values) {
    for (final link in (_relationshipLinks[entry] ?? {}).entries) {
      final parent = link.value;
      final parentValues = parent?.type.encode(parent.entity);
      for (var i = 0; i < link.key.columns.length; i++) {
        if (parent == null && !link.key.columns[i].nullable) continue;
        final desired = parent == null
            ? null
            : parentValues![link.key.targetColumns[i].sqlName];
        if (desired == null && parent != null ||
            !ormValuesEqual(values[link.key.columns[i].sqlName], desired)) {
          return true;
        }
      }
    }
    return false;
  }

  _SaveBatch _freeze() {
    final tracked = _entries.values.toList();
    final frozen = <EntityEntry<dynamic>, Map<String, Object?>>{};
    final plans = <_SaveIntent>[];
    for (final entry in tracked) {
      final values = entry.type.encode(entry.entity);
      _checkKey(entry, values);
      _validateRelationshipLinks(entry);
      frozen[entry] = _copyOrmRow(values);
      var state = entry._state;
      if (state == EntityState.unchanged) {
        state = !_ormRowsEqual(values, entry._snapshot) ||
                _relationshipChanged(entry, values)
            ? EntityState.modified
            : EntityState.unchanged;
      }
      if (state == EntityState.unchanged || state == EntityState.detached) {
        continue;
      }
      final version = entry.type.versionColumn;
      if (version != null &&
          state != EntityState.added &&
          !ormValuesEqual(
              values[version.sqlName], entry._snapshot[version.sqlName])) {
        throw const OrmStateException(
            'Version properties are managed by the context');
      }
      plans.add(_SaveIntent(
          entry,
          state,
          _copyOrmRow(values),
          _copyOrmRow(entry._snapshot),
          Map.of(_relationshipLinks[entry] ?? {}),
          Map.of(_relationshipLinkVersions[entry] ?? {})));
    }
    final writes =
        plans.where((plan) => plan.state != EntityState.deleted).toList();
    final deletes =
        plans.where((plan) => plan.state == EntityState.deleted).toList();
    return _SaveBatch(
        _orderWrites(writes), _orderDeletes(deletes), tracked, frozen);
  }

  List<_SaveIntent> _orderWrites(List<_SaveIntent> plans) {
    final pending = [...plans];
    final ordered = <_SaveIntent>[];
    final edges =
        <_SaveIntent, Map<_SaveIntent, List<ForeignKey<dynamic, dynamic>>>>{};
    for (final plan in plans) {
      final needs = edges[plan] = {};
      for (final key in model.foreignKeys
          .where((key) => identical(key.child, plan.entry.type))) {
        final linked = plan.links.containsKey(key) ? plan.links[key] : null;
        for (final parent in plans
            .where((other) => identical(other.entry.type, key.parent))) {
          if (parent.state != EntityState.added &&
              key.targetColumns.every((column) => ormValuesEqual(
                  parent.values[column.sqlName],
                  parent.original[column.sqlName]))) {
            continue;
          }
          final matches = linked != null
              ? identical(parent.entry, linked)
              : !plan.links.containsKey(key) &&
                  List.generate(key.columns.length, (i) => i).every((i) =>
                      plan.values[key.columns[i].sqlName] != null &&
                      ormValuesEqual(plan.values[key.columns[i].sqlName],
                          parent.values[key.targetColumns[i].sqlName]));
          if (matches) (needs[parent] ??= []).add(key);
        }
      }
    }
    while (pending.isNotEmpty) {
      final ready = pending
          .where((plan) =>
              edges[plan]!.keys.every((needed) => !pending.contains(needed)))
          .toList();
      if (ready.isEmpty) {
        final cycle = _nextCycle(pending, edges);
        final deferredKnown = cycle.every((plan) =>
            plan.entry.type.keys
                .every((column) => plan.values[column.sqlName] != null) &&
            edges[plan]!
                .entries
                .where((edge) => cycle.contains(edge.key))
                .every((edge) => edge.value.every((key) => key.deferred)));
        if (!deferredKnown) {
          throw const OrmStateException(
              'Relationship cycle needs known keys and deferred constraints');
        }
        ordered.addAll(cycle);
        pending.removeWhere(cycle.contains);
        continue;
      }
      ordered.addAll(ready);
      pending.removeWhere(ready.contains);
    }
    return ordered;
  }

  List<_SaveIntent> _nextCycle(
      List<_SaveIntent> pending,
      Map<_SaveIntent, Map<_SaveIntent, List<ForeignKey<dynamic, dynamic>>>>
          edges) {
    Set<_SaveIntent> reachable(_SaveIntent start, bool reverse) {
      final found = <_SaveIntent>{};
      final queue = [start];
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        if (!found.add(current)) continue;
        queue.addAll(reverse
            ? pending.where((plan) => edges[plan]!.containsKey(current))
            : edges[current]!.keys.where(pending.contains));
      }
      return found;
    }

    for (final candidate in pending) {
      final cycle =
          reachable(candidate, false).intersection(reachable(candidate, true));
      if (cycle.every((plan) => edges[plan]!.keys.every(
          (needed) => !pending.contains(needed) || cycle.contains(needed)))) {
        return pending.where(cycle.contains).toList();
      }
    }
    throw const OrmStateException('Cannot order relationship dependencies');
  }

  List<_SaveIntent> _orderDeletes(List<_SaveIntent> plans) {
    final pending = [...plans];
    final ordered = <_SaveIntent>[];
    while (pending.isNotEmpty) {
      final ready = pending
          .where((parent) => !pending.any((child) =>
              !identical(parent, child) &&
              model.foreignKeys.any((key) =>
                  identical(key.parent, parent.entry.type) &&
                  identical(key.child, child.entry.type) &&
                  List.generate(key.columns.length, (i) => i).every((i) =>
                      child.original[key.columns[i].sqlName] != null &&
                      ormValuesEqual(child.original[key.columns[i].sqlName],
                          parent.original[key.targetColumns[i].sqlName])))))
          .toList();
      if (ready.isEmpty) {
        final deferred = model.foreignKeys
            .where((key) =>
                pending.any((plan) => identical(plan.entry.type, key.child)) &&
                pending.any((plan) => identical(plan.entry.type, key.parent)))
            .every((key) =>
                key.deferred || key.onDelete == ForeignKeyAction.cascade);
        if (!deferred) {
          throw const OrmStateException(
              'Delete relationship cycle is not deferred');
        }
        ordered.addAll(pending);
        break;
      }
      ordered.addAll(ready);
      pending.removeWhere(ready.contains);
    }
    return ordered;
  }

  /// Snapshots the requested values synchronously before queuing SQL.
  Future<int> saveChanges() {
    try {
      _checkUsable();
      if (_savePending) {
        throw const OrmStateException('A save is already pending');
      }
      final batch = _freeze();
      _savePending = true;
      return _run(() => _save(batch)).whenComplete(() => _savePending = false);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  String _columnList(EntityType<dynamic> type) =>
      type.columns.map((column) => quoteIdentifier(column.sqlName)).join(',');

  Map<String, Object?> _writeValues(
      _SaveIntent plan,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Map<EntityEntry<dynamic>, Map<String, Object?>> frozenValues) {
    final values = _copyOrmRow(plan.values);
    for (final link in plan.links.entries) {
      final parent = link.value;
      final parentValues =
          parent == null ? null : stored[parent] ?? frozenValues[parent];
      for (var i = 0; i < link.key.columns.length; i++) {
        if (parent == null && !link.key.columns[i].nullable) continue;
        final value = parentValues?[link.key.targetColumns[i].sqlName];
        if (parent != null && value == null) {
          throw const OrmStateException(
              'Parent key was not generated before child write');
        }
        final column = link.key.columns[i];
        values[column.sqlName] = column.encodeValue(column.decodeValue(value));
      }
    }
    final version = plan.entry.type.versionColumn;
    if (plan.state == EntityState.modified && version != null) {
      final original = plan.original[version.sqlName];
      if (original is! BigInt) {
        throw const OrmStateException('Version must be INTEGER');
      }
      values[version.sqlName] =
          version.encodeValue(version.decodeValue(original + BigInt.one));
    }
    return values;
  }

  Future<Map<String, Object?>?> _readStored(
      EntityType<dynamic> type, Map<String, Object?> values) async {
    final result = await connection.query(
        'SELECT ${_columnList(type)} FROM ${quoteIdentifier(type.tableName)} WHERE '
        '${type.keys.map((column) => '${quoteIdentifier(column.sqlName)} IS ?').join(' AND ')}',
        [for (final column in type.keys) values[column.sqlName]]);
    if (result.rows.isEmpty) return null;
    if (result.rows.length != 1) {
      throw const OrmStateException('Store key selected multiple rows');
    }
    return _storedValues(type, _reader(result, result.rows.single));
  }

  bool _isCascadeDeleted(
      EntityEntry<dynamic> entry,
      Map<String, Object?> values,
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Set<EntityEntry<dynamic>> visited,
      {bool allowExplicitDelete = true}) {
    if (!visited.add(entry)) return false;
    if (allowExplicitDelete &&
        stored.containsKey(entry) &&
        stored[entry] == null &&
        batch.deletes.any((plan) => identical(plan.entry, entry))) {
      return true;
    }
    for (final key in model.foreignKeys.where((key) =>
        identical(key.child, entry.type) &&
        key.onDelete == ForeignKeyAction.cascade)) {
      for (final parent in batch.tracked
          .where((parent) => identical(parent.type, key.parent))) {
        final parentValues = stored[parent] ?? batch.frozenValues[parent]!;
        if (List.generate(key.columns.length, (i) => i).every((i) =>
                values[key.columns[i].sqlName] != null &&
                ormValuesEqual(values[key.columns[i].sqlName],
                    parentValues[key.targetColumns[i].sqlName])) &&
            _isCascadeDeleted(
                parent, parentValues, batch, stored, {...visited})) {
          return true;
        }
      }
    }
    return false;
  }

  Future<int> _save(_SaveBatch batch) async {
    if (batch.writes.isEmpty && batch.deletes.isEmpty) return 0;
    if (connection.inTransaction) {
      throw const OrmStateException('Save cannot join an external transaction');
    }
    var began = false, committing = false;
    final stored = <EntityEntry<dynamic>, Map<String, Object?>?>{};
    final byEntry = {
      for (final plan in [...batch.writes, ...batch.deletes]) plan.entry: plan
    };
    try {
      began = true;
      await connection.execute('BEGIN');
      for (final plan in batch.writes) {
        final type = plan.entry.type;
        final values = _writeValues(plan, stored, batch.frozenValues);
        final bound = <Object?>[];
        String sql;
        if (plan.state == EntityState.added) {
          final columns = type.columns
              .where((column) =>
                  !(column.generated && values[column.sqlName] == null))
              .toList();
          sql = columns.isEmpty
              ? 'INSERT INTO ${quoteIdentifier(type.tableName)} DEFAULT VALUES'
              : 'INSERT INTO ${quoteIdentifier(type.tableName)} '
                  '(${columns.map((column) => quoteIdentifier(column.sqlName)).join(',')}) '
                  'VALUES(${columns.map((_) => '?').join(',')})';
          bound.addAll(columns.map((column) => values[column.sqlName]));
        } else {
          final columns = type.columns
              .where((column) =>
                  column.keyOrder == null &&
                  !ormValuesEqual(
                      values[column.sqlName], plan.original[column.sqlName]))
              .toList();
          if (columns.isEmpty) {
            stored[plan.entry] = plan.original;
            continue;
          }
          sql = 'UPDATE ${quoteIdentifier(type.tableName)} SET '
              '${columns.map((column) => '${quoteIdentifier(column.sqlName)}=?').join(',')} WHERE ';
          bound.addAll(columns.map((column) => values[column.sqlName]));
          sql += _matchOriginal(type, plan.original, bound);
        }
        final mutation = await connection.execute(
            '$sql RETURNING ${_columnList(type)}', bound);
        final returned = mutation.returning;
        if (mutation.changes != 1 ||
            returned == null ||
            returned.rows.length != 1) {
          throw const OptimisticConcurrencyException(
              'Tracked write did not affect exactly one row');
        }
        final returnedValues =
            _storedValues(type, _reader(returned, returned.rows.single));
        final persisted = await _readStored(type, returnedValues);
        if (persisted == null) {
          throw const OrmStateException(
              'A trigger deleted the row or changed its primary key');
        }
        // Validate factories before committing, without mutating tracked objects.
        type.create(RowReader(persisted));
        stored[plan.entry] = persisted;
      }
      for (final plan in batch.deletes) {
        final bound = <Object?>[];
        final mutation = await connection.execute(
            'DELETE FROM ${quoteIdentifier(plan.entry.type.tableName)} WHERE '
            '${_matchOriginal(plan.entry.type, plan.original, bound)}',
            bound);
        if (mutation.changes != 1 &&
            !(mutation.changes == 0 &&
                _isCascadeDeleted(plan.entry, plan.original, batch, stored, {},
                    allowExplicitDelete: false) &&
                await _readStored(plan.entry.type, plan.original) == null)) {
          throw const OptimisticConcurrencyException(
              'Tracked delete did not affect exactly one row');
        }
        stored[plan.entry] = null;
      }
      // Trigger/FK actions can change other tracked rows. Refresh their baselines
      // inside the transaction; publish values only after the outer commit.
      for (final entry in batch.tracked) {
        if (byEntry[entry]?.state == EntityState.deleted) continue;
        final values = stored[entry] ?? batch.frozenValues[entry]!;
        if (entry._state == EntityState.added && !stored.containsKey(entry)) {
          continue;
        }
        final refreshed = await _readStored(entry.type, values);
        if (byEntry.containsKey(entry) &&
            refreshed == null &&
            !_isCascadeDeleted(entry, values, batch, stored, {})) {
          throw const OrmStateException(
              'A store action removed a saved tracked row');
        }
        if (refreshed != null) entry.type.create(RowReader(refreshed));
        stored[entry] = refreshed;
      }
      final identities =
          <EntityType<dynamic>, Map<EntityKey, EntityEntry<dynamic>>>{};
      for (final entry in batch.tracked) {
        final values = stored.containsKey(entry)
            ? stored[entry]
            : batch.frozenValues[entry];
        if (values == null) continue;
        // Unsaved generated keys have no permanent identity yet.
        if (entry.type.generatedKey != null &&
            values[entry.type.generatedKey!.sqlName] == null) {
          continue;
        }
        final identity = _ormRowKey(entry.type, values);
        if ((identities[entry.type] ??= {}).containsKey(identity)) {
          throw const OrmStateException(
              'Store generated a duplicate tracked identity');
        }
        identities[entry.type]![identity] = entry;
      }
      committing = true;
      await connection.execute('COMMIT');
      committing = false;
      began = false;
    } catch (error, stack) {
      Object? cleanup;
      final knownConstraint = error is SqlConstraintException;
      if (began) {
        try {
          if (connection.inTransaction) await connection.execute('ROLLBACK');
        } catch (rollbackError) {
          cleanup = rollbackError;
        }
      }
      if (cleanup != null || committing && !knownConstraint) _poisoned = true;
      if (cleanup != null) {
        Error.throwWithStackTrace(
            OrmStateException('Save failed and rollback also failed',
                (operation: error, rollback: cleanup)),
            stack);
      }
      Error.throwWithStackTrace(error, stack);
    }
    try {
      for (final entry in batch.tracked) {
        if (!stored.containsKey(entry)) continue;
        final row = stored[entry];
        if (row == null) {
          _detach(entry);
          continue;
        }
        _publish(entry, row, batch.frozenValues[entry]!);
      }
      for (final plan in [...batch.writes, ...batch.deletes]) {
        for (final key in plan.linkVersions.keys) {
          if (_relationshipLinkVersions[plan.entry]?[key] ==
              plan.linkVersions[key]) {
            _relationshipLinks[plan.entry]?.remove(key);
            _relationshipLinkValues[plan.entry]?.remove(key);
            _relationshipLinkVersions[plan.entry]?.remove(key);
          }
        }
      }
    } catch (error) {
      _poisoned = true;
      throw OrmStateException(
          'Save committed but applying mapped store values failed', error);
    }
    return batch.writes.length + batch.deletes.length;
  }

  String _matchOriginal(EntityType<dynamic> type, Map<String, Object?> original,
      List<Object?> parameters) {
    final columns = [
      ...type.keys,
      if (type.versionColumn != null) type.versionColumn!
    ];
    parameters.addAll(columns.map((column) => original[column.sqlName]));
    return columns
        .map((column) => '${quoteIdentifier(column.sqlName)} IS ?')
        .join(' AND ');
  }

  void _publish(EntityEntry<dynamic> entry, Map<String, Object?> stored,
      Map<String, Object?> frozen) {
    final current = entry.type.encode(entry.entity);
    final values = <String, Object?>{
      for (final column in entry.type.columns)
        column.sqlName:
            ormValuesEqual(current[column.sqlName], frozen[column.sqlName])
                ? stored[column.sqlName]
                : current[column.sqlName]
    };
    final linksBefore = <ForeignKey<dynamic, dynamic>, bool>{
      for (final link in (_relationshipLinkValues[entry] ?? {}).entries)
        link.key: List.generate(link.key.columns.length, (i) => i).every((i) =>
            ormValuesEqual(link.value[i], current[link.key.columns[i].sqlName]))
    };
    final old = entry.entity;
    if (!_ormRowsEqual(current, values)) {
      final reader = RowReader(values);
      if (entry.type.canApplyStoreValues) {
        entry._entity = entry.type.applyValues(entry.entity, reader);
      } else if (entry.type.columns.every((column) =>
          ormValuesEqual(current[column.sqlName], values[column.sqlName]) ||
          column.writable)) {
        for (final column in entry.type.columns) {
          if (!ormValuesEqual(
              current[column.sqlName], values[column.sqlName])) {
            column.writeEncoded(entry.entity, values[column.sqlName]);
          }
        }
      } else {
        entry._entity = entry.type.create(reader);
      }
    }
    if (!identical(old, entry.entity)) {
      final existing = _entries[entry.entity];
      if (existing != null && !identical(existing, entry)) {
        throw const OrmMappingException('Factory reused a tracked object');
      }
      _entries.remove(old);
      _entries[entry.entity as Object] = entry;
    }
    if (entry._identity != null) {
      _identities[entry.type]?.remove(entry._identity);
    }
    final identity = _ormRowKey(entry.type, stored);
    final existing = _identities[entry.type]?[identity];
    if (existing != null && !identical(existing, entry)) {
      throw const OrmStateException(
          'Store generated a duplicate tracked identity');
    }
    entry._identity = identity;
    (_identities[entry.type] ??= {})[identity] = entry;
    entry._snapshot = _copyOrmRow(stored);
    entry._state = EntityState.unchanged;
    for (final key in linksBefore.keys) {
      if (linksBefore[key] == true) {
        (_relationshipLinkValues[entry] ??= {})[key] = [
          for (final column in key.columns) column.readEncoded(entry.entity)
        ];
      }
    }
  }

  Future<void> close() {
    if (_closed) return Future.value();
    if (_closing) return _tail;
    _closing = true;
    final closed = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        _closed = true;
        for (final entry in _entries.values.toList()) {
          _detach(entry);
        }
        connection.release(this);
        await connection.close();
        closed.complete();
      } catch (error, stack) {
        closed.completeError(error, stack);
      }
    });
    return closed.future;
  }
}
