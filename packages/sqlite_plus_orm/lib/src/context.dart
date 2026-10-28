part of '../sqlite_plus_orm.dart';

/// Where an entity sits in the unit of work.
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

/// One tracked entity and the snapshot taken when it was loaded or saved.
final class EntityEntry<T> {
  EntityEntry._(this.context, this.type, this._entity, this._state,
      this._snapshot, this._identity);

  /// Context that tracks this entry.
  final DbContext context;

  /// Mapping used to read and write the entity.
  final EntityType<T> type;
  T _entity;

  /// The current object. [DbSet.replace] can change it.
  T get entity => _entity;
  EntityState _state;
  Map<String, Object?> _snapshot;
  EntityKey? _identity;

  /// Added, unchanged, modified, deleted, or detached.
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

/// The tracked set of one entity type.
final class DbSet<T> {
  DbSet._(this.context, this.type);

  /// Context that owns this set.
  final DbContext context;

  /// Mapping for [T].
  final EntityType<T> type;

  /// Tracks [entity] as added. The insert happens in [DbContext.saveChanges].
  EntityEntry<T> add(T entity) => context._track(type, entity, true);

  /// Tracks [entity] as already stored.
  EntityEntry<T> attach(T entity) => context._track(type, entity, false);

  /// Marks [entity] deleted, or detaches it when it was only added.
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

  /// Keeps the tracking entry but swaps the object instance.
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

  /// Query that materializes rows into this set's identity map.
  TypedQuery<T> get query => TypedQuery<T>(
      type: type,
      connection: context.connection,
      materialize: (row) => context._materialize(type, row),
      serialize: context._run);

  /// The tracked entity for [key], loading it when it is not already tracked.
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
  /// Claims [connection] exclusively for this context and [model].
  DbContext(this.connection, this.model) {
    connection.claim(this);
  }

  /// Connection used for every statement.
  final OrmConnection connection;

  /// Entity mappings and foreign keys.
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

  /// Schema planner bound to this context's connection and model.
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

  /// The set for [type]. The type must belong to [model].
  DbSet<T> set<T>(EntityType<T> type) {
    _checkUsable();
    if (!model.entities.contains(type)) {
      throw const OrmMappingException('Entity mapping is not registered');
    }
    return DbSet._(this, type);
  }

  /// The tracking entry for an object already known to this context.
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
  /// Writes added, modified, and deleted entities in one transaction.
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

  static const _maxInsertParameters = 20000;
  static const _maxInsertSql = 900000;

  Future<Set<String>> _triggerTables() async {
    final result = await connection
        .query("SELECT tbl_name FROM sqlite_schema WHERE type='trigger'");
    return {
      for (final row in result.rows)
        if (row.isNotEmpty && row.first is String)
          (row.first! as String).toLowerCase()
    };
  }

  bool _rewritesRows(ForeignKeyAction action) =>
      action == ForeignKeyAction.cascade ||
      action == ForeignKeyAction.setNull ||
      action == ForeignKeyAction.setDefault;

  bool _needsBroadRefresh(_SaveBatch batch, Set<String> triggerTables) {
    bool triggered(EntityType<dynamic> type) =>
        triggerTables.contains(type.tableName.toLowerCase());
    if (batch.writes.any((plan) => triggered(plan.entry.type)) ||
        batch.deletes.any((plan) => triggered(plan.entry.type))) {
      return true;
    }
    final deleted = [for (final plan in batch.deletes) plan.entry.type];
    final updated = [
      for (final plan in batch.writes)
        if (plan.state != EntityState.added) plan.entry.type
    ];
    for (final key in model.foreignKeys) {
      final parentDeleted = deleted.any((type) => identical(type, key.parent));
      final parentUpdated = updated.any((type) => identical(type, key.parent));
      if (parentDeleted && _rewritesRows(key.onDelete)) return true;
      if (parentUpdated && _rewritesRows(key.onUpdate)) return true;
    }
    return false;
  }

  List<Column<dynamic, dynamic>> _insertColumns(
          EntityType<dynamic> type, Map<String, Object?> values) =>
      type.columns
          .where(
              (column) => !(column.generated && values[column.sqlName] == null))
          .toList();

  bool _sameColumns(List<Column<dynamic, dynamic>> left,
      List<Column<dynamic, dynamic>> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!identical(left[i], right[i])) return false;
    }
    return true;
  }

  bool _dependsOnPendingParent(
      _SaveIntent plan, Set<EntityEntry<dynamic>> pending) {
    for (final parent in plan.links.values) {
      if (parent != null && pending.contains(parent)) return true;
    }
    return false;
  }

  void _keepPersisted(
      EntityType<dynamic> type,
      EntityEntry<dynamic> entry,
      Map<String, Object?> values,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored) {
    type.create(RowReader(values));
    stored[entry] = values;
  }

  Future<void> _writePlans(
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Set<String> triggerTables) async {
    final plans = batch.writes;
    var index = 0;
    while (index < plans.length) {
      final plan = plans[index];
      final type = plan.entry.type;
      final values = _writeValues(plan, stored, batch.frozenValues);
      final columns = plan.state == EntityState.added
          ? _insertColumns(type, values)
          : const <Column<dynamic, dynamic>>[];
      final batchable = plan.state == EntityState.added &&
          type.virtualModule == null &&
          columns.isNotEmpty &&
          !triggerTables.contains(type.tableName.toLowerCase());
      if (!batchable) {
        await _writeSingle(plan, values, stored, triggerTables);
        index++;
        continue;
      }
      final group = <(_SaveIntent, Map<String, Object?>)>[(plan, values)];
      final pending = <EntityEntry<dynamic>>{plan.entry};
      var sqlLength = _insertSqlLength(type, columns, 1);
      index++;
      while (index < plans.length &&
          group.length * columns.length < _maxInsertParameters &&
          sqlLength < _maxInsertSql) {
        final candidate = plans[index];
        if (candidate.state != EntityState.added ||
            !identical(candidate.entry.type, type) ||
            triggerTables.contains(type.tableName.toLowerCase()) ||
            _dependsOnPendingParent(candidate, pending)) {
          break;
        }
        final candidateValues =
            _writeValues(candidate, stored, batch.frozenValues);
        if (!_sameColumns(columns, _insertColumns(type, candidateValues))) {
          break;
        }
        final nextLength = _insertSqlLength(type, columns, group.length + 1);
        if ((group.length + 1) * columns.length > _maxInsertParameters ||
            nextLength > _maxInsertSql) {
          break;
        }
        group.add((candidate, candidateValues));
        pending.add(candidate.entry);
        sqlLength = nextLength;
        index++;
      }
      if (group.length == 1) {
        await _writeSingle(plan, values, stored, triggerTables);
      } else {
        await _writeAddedBatch(type, columns, group, stored);
      }
    }
  }

  int _insertSqlLength(EntityType<dynamic> type,
      List<Column<dynamic, dynamic>> columns, int rows) {
    return type.tableName.length +
        columns.fold<int>(0, (sum, column) => sum + column.sqlName.length) +
        rows * (columns.length * 2 + 4) +
        64;
  }

  Future<void> _writeAddedBatch(
      EntityType<dynamic> type,
      List<Column<dynamic, dynamic>> columns,
      List<(_SaveIntent, Map<String, Object?>)> group,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored) async {
    final placeholders = '(${List.filled(columns.length, '?').join(',')})';
    final sql = 'INSERT INTO ${quoteIdentifier(type.tableName)} '
        '(${columns.map((column) => quoteIdentifier(column.sqlName)).join(',')}) '
        'VALUES ${List.filled(group.length, placeholders).join(',')} '
        'RETURNING ${_columnList(type)}';
    final bound = <Object?>[
      for (final row in group)
        for (final column in columns) row.$2[column.sqlName]
    ];
    final mutation = await connection.execute(sql, bound);
    final returned = mutation.returning;
    if (mutation.changes != group.length ||
        returned == null ||
        returned.rows.length != group.length) {
      throw const OptimisticConcurrencyException(
          'Tracked write did not affect exactly one row');
    }
    for (var i = 0; i < group.length; i++) {
      _keepPersisted(type, group[i].$1.entry,
          _storedValues(type, _reader(returned, returned.rows[i])), stored);
    }
  }

  Future<void> _writeSingle(
      _SaveIntent plan,
      Map<String, Object?> values,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Set<String> triggerTables) async {
    final type = plan.entry.type;
    final bound = <Object?>[];
    String sql;
    if (plan.state == EntityState.added) {
      final columns = _insertColumns(type, values);
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
        return;
      }
      sql = 'UPDATE ${quoteIdentifier(type.tableName)} SET '
          '${columns.map((column) => '${quoteIdentifier(column.sqlName)}=?').join(',')} WHERE ';
      bound.addAll(columns.map((column) => values[column.sqlName]));
      sql += _matchOriginal(type, plan.original, bound);
    }
    final mutation = await connection.execute(
        type.virtualModule == null
            ? '$sql RETURNING ${_columnList(type)}'
            : sql,
        bound);
    final Map<String, Object?> persisted;
    if (type.virtualModule == null) {
      final returned = mutation.returning;
      if (mutation.changes != 1 ||
          returned == null ||
          returned.rows.length != 1) {
        throw const OptimisticConcurrencyException(
            'Tracked write did not affect exactly one row');
      }
      final returnedValues =
          _storedValues(type, _reader(returned, returned.rows.single));
      final trustReturning = plan.state == EntityState.added &&
          !triggerTables.contains(type.tableName.toLowerCase());
      if (trustReturning) {
        persisted = returnedValues;
      } else {
        final read = await _readStored(type, returnedValues);
        if (read == null) {
          throw const OrmStateException(
              'A trigger deleted the row or changed its primary key');
        }
        persisted = read;
      }
    } else {
      // FTS and R-tree writes reject RETURNING. Read the saved row back.
      if (mutation.changes != 1) {
        throw const OptimisticConcurrencyException(
            'Tracked write did not affect exactly one row');
      }
      final generated = type.generatedKey;
      if (plan.state == EntityState.added &&
          generated != null &&
          values[generated.sqlName] == null) {
        final id = mutation.lastInsertRowid;
        if (id == null) {
          throw const OrmStateException(
              'Virtual table insert did not return a row id');
        }
        values[generated.sqlName] =
            generated.encodeValue(generated.decodeValue(id));
      }
      final read = await _readStored(type, values);
      if (read == null) {
        throw const OrmStateException(
            'A trigger deleted the row or changed its primary key');
      }
      persisted = read;
    }
    _keepPersisted(type, plan.entry, persisted, stored);
  }

  Future<void> _refreshTracked(
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Map<EntityEntry<dynamic>, _SaveIntent> byEntry) async {
    final types = <EntityType<dynamic>>[];
    for (final entry in batch.tracked) {
      if (byEntry[entry]?.state == EntityState.deleted) continue;
      if (types.any((type) => identical(type, entry.type))) continue;
      types.add(entry.type);
    }
    for (final type in types) {
      if (type.virtualModule != null) {
        await _refreshTypePointwise(type, batch, stored, byEntry);
      } else {
        await _refreshTypeBulk(type, batch, stored, byEntry);
      }
    }
  }

  Future<void> _refreshTypeBulk(
      EntityType<dynamic> type,
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Map<EntityEntry<dynamic>, _SaveIntent> byEntry) async {
    final result = await connection.query(
        'SELECT ${_columnList(type)} FROM ${quoteIdentifier(type.tableName)}');
    final rows = <EntityKey, Map<String, Object?>>{};
    for (final row in result.rows) {
      final values = _storedValues(type, _reader(result, row));
      final identity = _ormRowKey(type, values);
      if (rows.containsKey(identity)) {
        throw const OrmStateException('Store key selected multiple rows');
      }
      rows[identity] = values;
    }
    for (final entry in batch.tracked) {
      if (!identical(entry.type, type)) continue;
      if (byEntry[entry]?.state == EntityState.deleted) continue;
      final values = stored[entry] ?? batch.frozenValues[entry]!;
      if (entry._state == EntityState.added && !stored.containsKey(entry)) {
        continue;
      }
      final generated = type.generatedKey;
      final refreshed = generated != null && values[generated.sqlName] == null
          ? await _readStored(type, values)
          : rows[_ormRowKey(type, values)];
      _acceptRefresh(entry, values, refreshed, batch, stored, byEntry);
    }
  }

  Future<void> _refreshTypePointwise(
      EntityType<dynamic> type,
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Map<EntityEntry<dynamic>, _SaveIntent> byEntry) async {
    for (final entry in batch.tracked) {
      if (!identical(entry.type, type)) continue;
      if (byEntry[entry]?.state == EntityState.deleted) continue;
      final values = stored[entry] ?? batch.frozenValues[entry]!;
      if (entry._state == EntityState.added && !stored.containsKey(entry)) {
        continue;
      }
      _acceptRefresh(entry, values, await _readStored(type, values), batch,
          stored, byEntry);
    }
  }

  void _acceptRefresh(
      EntityEntry<dynamic> entry,
      Map<String, Object?> values,
      Map<String, Object?>? refreshed,
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Map<EntityEntry<dynamic>, _SaveIntent> byEntry) {
    if (byEntry.containsKey(entry) &&
        refreshed == null &&
        !_isCascadeDeleted(entry, values, batch, stored, {})) {
      throw const OrmStateException(
          'A store action removed a saved tracked row');
    }
    if (refreshed != null) entry.type.create(RowReader(refreshed));
    stored[entry] = refreshed;
  }

  Future<void> _deletePlans(
      _SaveBatch batch,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored,
      Set<String> triggerTables) async {
    final plans = batch.deletes;
    var index = 0;
    while (index < plans.length) {
      final plan = plans[index];
      final type = plan.entry.type;
      final batchable = type.virtualModule == null &&
          !triggerTables.contains(type.tableName.toLowerCase()) &&
          !model.foreignKeys.any((key) =>
              identical(key.parent, type) && _rewritesRows(key.onDelete));
      if (!batchable) {
        await _deleteSingle(batch, plan, stored);
        index++;
        continue;
      }
      final sample = <Object?>[];
      _matchOriginal(type, plan.original, sample);
      final perRow = sample.length;
      final group = <_SaveIntent>[plan];
      index++;
      while (index < plans.length) {
        final candidate = plans[index];
        if (!identical(candidate.entry.type, type)) break;
        final next = group.length + 1;
        if (next * perRow > _maxInsertParameters ||
            _deleteSqlLength(type, perRow, next) > _maxInsertSql) {
          break;
        }
        group.add(candidate);
        index++;
      }
      if (group.length == 1) {
        await _deleteSingle(batch, plan, stored);
      } else {
        await _deleteBatch(batch, type, group, stored);
      }
    }
  }

  int _deleteSqlLength(
          EntityType<dynamic> type, int parametersPerRow, int rows) =>
      type.tableName.length + rows * (parametersPerRow * 6 + 12) + 32;

  Future<void> _deleteSingle(_SaveBatch batch, _SaveIntent plan,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored) async {
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

  Future<void> _deleteBatch(
      _SaveBatch batch,
      EntityType<dynamic> type,
      List<_SaveIntent> group,
      Map<EntityEntry<dynamic>, Map<String, Object?>?> stored) async {
    final bound = <Object?>[];
    final probe = <Object?>[];
    final sample = _matchOriginal(type, group.first.original, probe);
    final singleColumn = !sample.contains(' AND ');
    final String where;
    final column = !singleColumn
        ? null
        : type.versionColumn == null
            ? type.keys.single.sqlName
            : type.versionColumn!.sqlName;
    final values = column == null
        ? const <Object?>[]
        : [for (final plan in group) plan.original[column]];
    // IN does not match NULL. A null key stays on the IS comparison.
    var deleteAll = false;
    if (column != null && values.every((value) => value != null)) {
      final counted = await connection
          .query('SELECT COUNT(*) FROM ${quoteIdentifier(type.tableName)}');
      final total = counted.rows.single.single;
      if (total == group.length || total == BigInt.from(group.length)) {
        // Every stored row is in this group. One unfiltered DELETE avoids a
        // search of the key list for every row.
        deleteAll = true;
        where = '';
      } else {
        bound.addAll(values);
        where =
            '${quoteIdentifier(column)} IN (${List.filled(group.length, '?').join(',')})';
      }
    } else {
      final clauses = <String>[
        for (final plan in group)
          '(${_matchOriginal(type, plan.original, bound)})'
      ];
      where = clauses.join(' OR ');
    }
    final mutation = await connection.execute(
        deleteAll
            ? 'DELETE FROM ${quoteIdentifier(type.tableName)}'
            : 'DELETE FROM ${quoteIdentifier(type.tableName)} WHERE $where',
        bound);
    if (mutation.changes != group.length) {
      var accounted = 0;
      for (final plan in group) {
        final gone = await _readStored(type, plan.original) == null;
        if (!gone) {
          throw const OptimisticConcurrencyException(
              'Tracked delete did not affect exactly one row');
        }
        final cascade = _isCascadeDeleted(
            plan.entry, plan.original, batch, stored, {},
            allowExplicitDelete: false);
        if (!cascade) accounted++;
      }
      if (mutation.changes != accounted) {
        throw const OptimisticConcurrencyException(
            'Tracked delete did not affect exactly one row');
      }
    }
    for (final plan in group) {
      stored[plan.entry] = null;
    }
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
      final triggerTables = await _triggerTables();
      await _writePlans(batch, stored, triggerTables);
      await _deletePlans(batch, stored, triggerTables);
      // A trigger or a rewriting foreign-key action can change rows other than
      // the one just written. One read of each affected table sees that state.
      // Plain inserts already carry it in RETURNING, so they do not reread.
      if (_needsBroadRefresh(batch, triggerTables)) {
        await _refreshTracked(batch, stored, byEntry);
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

  /// Releases the connection. Later calls fail.
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
