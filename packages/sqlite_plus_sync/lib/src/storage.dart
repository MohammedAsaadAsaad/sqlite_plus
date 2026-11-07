part of 'sync.dart';

const _ddl = <String, String>{
  '_spsync_state':
      'CREATE TABLE _spsync_state(id INTEGER PRIMARY KEY,format INTEGER NOT NULL,scope TEXT NOT NULL,replica TEXT NOT NULL,feed TEXT NOT NULL,initial_batch INTEGER NOT NULL,next_operation INTEGER NOT NULL,cursor TEXT)',
  '_spsync_tables':
      'CREATE TABLE _spsync_tables(id INTEGER PRIMARY KEY,name TEXT NOT NULL,keys_json TEXT NOT NULL,columns_json TEXT NOT NULL,schema_sql TEXT NOT NULL)',
  '_spsync_rows':
      'CREATE TABLE _spsync_rows(id INTEGER PRIMARY KEY,table_id INTEGER NOT NULL,key_json TEXT NOT NULL,version TEXT,tombstone INTEGER NOT NULL,discard_through INTEGER NOT NULL,force_full INTEGER NOT NULL)',
  '_spsync_outbox':
      'CREATE TABLE _spsync_outbox(id INTEGER PRIMARY KEY,operation_id TEXT NOT NULL,payload TEXT NOT NULL)',
  '_spsync_remote':
      'CREATE TABLE _spsync_remote(id INTEGER PRIMARY KEY,feed TEXT NOT NULL,batch_id INTEGER NOT NULL)',
  '_spsync_conflicts':
      'CREATE TABLE _spsync_conflicts(id INTEGER PRIMARY KEY,kind TEXT NOT NULL,payload TEXT NOT NULL)',
  '_spsync_tables_name':
      'CREATE INDEX _spsync_tables_name ON _spsync_tables(name)',
  '_spsync_rows_key':
      'CREATE INDEX _spsync_rows_key ON _spsync_rows(table_id,key_json)',
  '_spsync_outbox_op':
      'CREATE INDEX _spsync_outbox_op ON _spsync_outbox(operation_id)',
  '_spsync_remote_batch':
      'CREATE INDEX _spsync_remote_batch ON _spsync_remote(batch_id)',
  '_spsync_conflicts_kind':
      'CREATE INDEX _spsync_conflicts_kind ON _spsync_conflicts(kind)',
};

final class _State {
  _State(this.replica, this.feed, this.initial, this.next, this.cursor);
  final String replica, feed;
  final BigInt initial, next;
  final String? cursor;
}

final class _Config {
  _Config(this.id, this.name, this.keys, this.columns);
  final BigInt id;
  final String name;
  final List<String> keys, columns;
  String key(Map<String, Object?> values) {
    if (values.length != keys.length || !keys.every(values.containsKey)) {
      throw const SyncProtocolException(
          'Incomplete/unknown primary key fields');
    }
    for (final value in values.values) {
      if (value is! String && value is! BigInt && value is! int) {
        throw const SyncProtocolException(
            'Keys must be non-null signed64 integer/text');
      }
      SyncCodec.value(value);
    }
    return jsonEncode(
        SyncCodec.fields({for (final key in keys) key: values[key]}));
  }
}

final class _Row {
  _Row(this.id, this.version, this.tombstone, this.discard, this.full);
  final BigInt? id, version;
  final bool tombstone, full;
  final BigInt discard;
}

extension _Storage on SqlitePlusSync {
  Future<void> _openStorage(ChangeCheckpoint head, String? replica) async {
    final schema =
        await database.query('SELECT type,name,sql FROM sqlite_schema');
    final owned = {
      for (final row in schema.rows)
        if ((row[1] as String).startsWith('_spsync_')) row[1]: row[2]
    };
    if (owned.isEmpty) {
      await database.execute('BEGIN');
      try {
        for (final sql in _ddl.values) {
          await database.execute(sql);
        }
        for (final table in ['outbox', 'remote', 'conflicts']) {
          await database.execute('INSERT INTO _spsync_$table VALUES(0,?,?)',
              table == 'remote' ? ['', 0] : ['', '']);
        }
        final random = Random.secure();
        final identity = replica ??
            List.generate(
                    16,
                    (_) =>
                        random.nextInt(256).toRadixString(16).padLeft(2, '0'))
                .join();
        await database.execute(
            'INSERT INTO _spsync_state VALUES(1,1,?,?,?,?,1,NULL)',
            [scope, identity, head.feedId, head.batch]);
        await database.execute('COMMIT');
      } catch (_) {
        if (database.inTransaction) {
          try {
            await database.execute('ROLLBACK');
          } catch (_) {/* Preserve the storage failure. */}
        }
        rethrow;
      }
    } else if (owned.length != _ddl.length ||
        _ddl.entries.any((e) => owned[e.key] != e.value)) {
      throw const SyncStateException(
          'Missing/altered Sync schema; no automatic migration');
    }
    if (replica != null) {
      final stored =
          await database.query('SELECT replica FROM _spsync_state WHERE id=1');
      if (stored.rows.length != 1 || stored.rows.single.single != replica) {
        throw const SyncStateException(
            'replicaId differs from persisted identity');
      }
    }
  }

  Future<_State> _state(ChangeWriter tx) async {
    final schema = await tx.query('SELECT name,sql FROM sqlite_schema');
    final entries = {
      for (final row in schema.rows)
        if ((row[0] as String).startsWith('_spsync_')) row[0]: row[1]
    };
    if (entries.length != _ddl.length ||
        _ddl.entries.any((e) => entries[e.key] != e.value)) {
      throw const SyncStateException('Missing/altered Sync schema');
    }
    final rows = (await tx.query(
            'SELECT id,format,scope,replica,feed,initial_batch,next_operation,cursor FROM _spsync_state'))
        .rows;
    if (rows.length != 1 ||
        rows.single[0] != BigInt.one ||
        rows.single[1] != BigInt.one) {
      throw const SyncStateException('Unsupported/malformed Sync state');
    }
    final row = rows.single;
    final initial = _int(row[5]), next = _int(row[6]);
    if (row[2] != scope ||
        row[4] != tx.baseCheckpoint.feedId ||
        row[3] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(row[3] as String) ||
        initial.isNegative ||
        initial > tx.baseCheckpoint.batch ||
        next < BigInt.one ||
        next >= _max ||
        row[7] != null && row[7] is! String) {
      throw const SyncStateException(
          'Namespace/generation mismatch or invalid identity/counters');
    }
    for (final name in ['outbox', 'remote', 'conflicts']) {
      if ((await tx.query('SELECT id FROM _spsync_$name WHERE id=0'))
              .rows
              .length !=
          1) {
        throw const SyncStateException('Missing metadata anchor');
      }
    }
    return _State(
        row[3] as String, row[4] as String, initial, next, row[7] as String?);
  }

  Future<List<_Config>> _configs(ChangeWriter tx) async {
    final rows = await tx.query(
        'SELECT id,name,keys_json,columns_json,schema_sql FROM _spsync_tables');
    final schema =
        await tx.query("SELECT name,sql FROM sqlite_schema WHERE type='table'");
    final definitions = {for (final row in schema.rows) row[0]: row[1]};
    final capture = {
      for (final source in await tx.sources()) source.table: source
    };
    final result = <_Config>[];
    final names = <String>{};
    for (final row in rows.rows) {
      final keys = (jsonDecode(row[2] as String) as List).cast<String>();
      final columns = (jsonDecode(row[3] as String) as List).cast<String>();
      final name = row[1] as String;
      if (_int(row[0]) < BigInt.one ||
          !names.add(name) ||
          keys.isEmpty ||
          keys.toSet().length != keys.length ||
          columns.toSet().length != columns.length ||
          !keys.every(columns.contains) ||
          definitions[name] != row[4]) {
        throw const SyncStateException('Malformed/changed table registration');
      }
      final tracked = capture[name];
      if (tracked == null ||
          jsonEncode(tracked.primaryKey) != jsonEncode(keys) ||
          !columns.every(tracked.columns.contains)) {
        throw const SyncStateException(
            'Registered sync table is no longer captured by Changes');
      }
      result.add(_Config(_int(row[0]), name, keys, columns));
    }
    return result;
  }

  // The connection is exclusively owned inside a Changes writer scope. Load
  // row revisions once per scope rather than forcing a full image read after
  // each metadata UPDATE. Expando lifetime follows the writer, never the DB.
  static final _rowCaches = Expando<Map<String, _Row>>();

  Future<Map<String, _Row>> _rowCache(ChangeWriter tx) async {
    final cached = _rowCaches[tx];
    if (cached != null) return cached;
    final configs = {for (final c in await _configs(tx)) c.id: c};
    final rows = await tx.query(
        'SELECT id,table_id,key_json,version,tombstone,discard_through,force_full FROM _spsync_rows');
    final result = <String, _Row>{};
    for (final row in rows.rows) {
      final config = configs[_int(row[1])];
      if (config == null) {
        throw const SyncStateException('Unknown row metadata table');
      }
      final key = SyncCodec.decodeFields(jsonDecode(row[2] as String));
      final canonical = config.key(key);
      final identity = '${config.id}:$canonical';
      final version = row[3] == null ? null : BigInt.parse(row[3] as String);
      if (canonical != row[2] ||
          result.containsKey(identity) ||
          _int(row[0]) < BigInt.one ||
          version != null &&
              (version < BigInt.one ||
                  version > _max ||
                  version.toString() != row[3]) ||
          _int(row[5]).isNegative ||
          _int(row[5]) > tx.baseCheckpoint.batch ||
          ![BigInt.zero, BigInt.one].contains(row[4]) ||
          ![BigInt.zero, BigInt.one].contains(row[6])) {
        throw const SyncStateException(
            'Invalid row metadata identity/revision/flags');
      }
      result[identity] = _Row(_int(row[0]), version, row[4] == BigInt.one,
          _int(row[5]), row[6] == BigInt.one);
    }
    _rowCaches[tx] = result;
    return result;
  }

  Future<_Row> _row(
          ChangeWriter tx, _Config config, Map<String, Object?> key) async =>
      (await _rowCache(tx))[_identity(config, key)] ??
      _Row(null, null, false, BigInt.zero, false);

  Future<void> _putRow(
      ChangeWriter tx, _Config config, Map<String, Object?> key,
      {BigInt? version, bool? tombstone, BigInt? discard, bool? full}) async {
    final old = await _row(tx, config, key);
    final nextVersion = version ?? old.version;
    final nextTombstone = tombstone ?? old.tombstone;
    final nextDiscard = discard ?? old.discard;
    final nextFull = full ?? old.full;
    final values = [
      nextVersion?.toString(),
      nextTombstone ? 1 : 0,
      nextDiscard,
      nextFull ? 1 : 0
    ];
    BigInt? id = old.id;
    if (id == null) {
      final result = await tx.execute(
          'INSERT INTO _spsync_rows(table_id,key_json,version,tombstone,discard_through,force_full) VALUES(?,?,?,?,?,?)',
          [config.id, config.key(key), ...values]);
      id = result.lastInsertRowid;
      if (id == null || id < BigInt.one) {
        throw const SyncStateException('Missing row metadata ID');
      }
    } else {
      await tx.execute(
          'UPDATE _spsync_rows SET version=?,tombstone=?,discard_through=?,force_full=? WHERE id=?',
          [...values, id]);
    }
    (await _rowCache(tx))[_identity(config, key)] =
        _Row(id, nextVersion, nextTombstone, nextDiscard, nextFull);
  }

  Future<Map<String, Object?>?> _source(
      ChangeWriter tx, _Config c, Map<String, Object?> key) async {
    c.key(key);
    final rows = await tx.query(
        'SELECT ${c.columns.map(_quote).join(',')} FROM ${_quote(c.name)} NOT INDEXED WHERE ${c.keys.map((k) => '${_quote(k)}=?').join(' AND ')}',
        [for (final k in c.keys) key[k]]);
    if (rows.rows.length > 1) {
      throw const SyncStateException('Non-unique source key');
    }
    return rows.rows.isEmpty
        ? null
        : {
            for (var i = 0; i < c.columns.length; i++)
              c.columns[i]: rows.rows.single[i]
          };
  }

  Future<SyncOperation?> _outbox(ChangeWriter tx) async {
    final rows = await tx
        .query('SELECT id,operation_id,payload FROM _spsync_outbox WHERE id>0');
    if (rows.rows.length > 1) {
      throw const SyncStateException('Multiple in-flight operations');
    }
    if (rows.rows.isEmpty) return null;
    final row = rows.rows.single;
    final op = SyncOperation.fromJson(_json(row[2] as String));
    final state = await _state(tx);
    if (_int(row[0]) < BigInt.one ||
        _int(row[0]) >= state.next ||
        op.id != '${state.replica}:${state.feed}:${row[0]}' ||
        row[1] != op.id ||
        op.scope != scope ||
        op.mutations.isEmpty ||
        op.mutations.length > 100000) {
      throw const SyncStateException('Malformed outbox identity or size');
    }
    final tables = {for (final c in await _configs(tx)) c.name: c};
    final seen = <String>{};
    for (final mutation in op.mutations) {
      final c = tables[mutation.table];
      if (c == null ||
          !seen.add(_identity(c, mutation.key)) ||
          mutation.baseVersion != null &&
              (mutation.baseVersion! < BigInt.one ||
                  mutation.baseVersion! > _max)) {
        throw const SyncStateException('Invalid outbox key/revision');
      }
      final values = mutation.values;
      if (values != null) {
        if (!values.keys.every(c.columns.contains) ||
            !c.keys.every(values.containsKey) ||
            c.key({for (final k in c.keys) k: values[k]}) !=
                c.key(mutation.key) ||
            mutation.baseVersion == null &&
                !c.columns.every(values.containsKey)) {
          throw const SyncStateException('Invalid outbox patch');
        }
        for (final value in values.values) {
          SyncCodec.value(value);
        }
      }
    }
    return op;
  }

  Future<List<Object?>?> _conflict(ChangeWriter tx) async {
    final rows = await tx
        .query('SELECT id,kind,payload FROM _spsync_conflicts WHERE id>0');
    if (rows.rows.length > 1) {
      throw const SyncStateException('Multiple blocking conflicts');
    }
    return rows.rows.firstOrNull;
  }

  Future<BigInt> _allocate(ChangeWriter tx, _State state) async {
    // Read again: a scope may allocate both a conflict and an operation.
    final next = _int(
        (await tx.query('SELECT next_operation FROM _spsync_state WHERE id=1'))
            .rows
            .single
            .single);
    if (next < state.next || next >= _max) {
      throw const SyncStateException('Sequence exhausted/corrupt');
    }
    await tx.execute('UPDATE _spsync_state SET next_operation=? WHERE id=1',
        [next + BigInt.one]);
    return next;
  }

  Future<SyncOperation> _enqueue(
      ChangeWriter tx, _State state, List<SyncMutation> mutations) async {
    if (mutations.isEmpty || await _outbox(tx) != null) {
      throw const SyncStateException('Outbox must be empty');
    }
    final id = await _allocate(tx, state);
    final op = SyncOperation(
        id: '${state.replica}:${state.feed}:$id',
        scope: scope,
        mutations: mutations);
    await tx.execute('INSERT INTO _spsync_outbox VALUES(?,?,?)',
        [id, op.id, jsonEncode(op.toJson())]);
    return op;
  }

  Future<void> _markRemote(ChangeWriter tx, List<SyncRecord> applied) async {
    final configs = {for (final c in await _configs(tx)) c.name: c};
    final expected = <String>{};
    for (final record in applied) {
      final c = configs[record.table]!;
      expected.add(_identity(c, record.key));
      final actual = await _source(tx, c, record.key);
      final remote = record.values;
      if ((actual == null) != (remote == null) ||
          actual != null &&
              jsonEncode(SyncCodec.fields(
                      {for (final k in c.columns) k: actual[k]})) !=
                  jsonEncode(SyncCodec.fields(
                      {for (final k in c.columns) k: remote![k]}))) {
        throw const SyncStateException(
            'Source affinity/trigger transformed the incoming row');
      }
    }
    final pending = await tx.pendingChanges();
    for (final event in pending.events) {
      final c = configs[event.table];
      if (c == null) continue;
      for (final key in [event.oldKey, event.newKey]) {
        if (key != null && !expected.contains(_identity(c, key))) {
          throw const SyncStateException(
              'Incoming trigger/cascade changed an unlisted synchronized key');
        }
      }
    }
    if (pending.transactions.isNotEmpty) {
      await tx.execute('INSERT INTO _spsync_remote(feed,batch_id) VALUES(?,?)',
          [pending.checkpoint.feedId, pending.checkpoint.batch]);
    }
  }

  Future<Set<BigInt>> _remoteBatches(ChangeWriter tx, String feed) async {
    final rows =
        await tx.query('SELECT feed,batch_id FROM _spsync_remote WHERE id>0');
    final result = <BigInt>{};
    for (final row in rows.rows) {
      final batch = _int(row[1]);
      if (row[0] != feed ||
          batch < BigInt.one ||
          batch > tx.baseCheckpoint.batch ||
          !result.add(batch)) {
        throw const SyncStateException('Malformed origin marker');
      }
    }
    return result;
  }
}
