part of 'sync.dart';

final class _Dirty {
  _Dirty(this.config, this.key);
  final _Config config;
  final Map<String, Object?> key;
  final fields = <String>{};
  bool full = false;
}

extension _Producer on SqlitePlusSync {
  String _identity(_Config c, Map<String, Object?> key) =>
      '${c.id}:${c.key(key)}';

  Future<Map<String, _Dirty>> _dirty(
      ChangeWriter tx, ChangeBatch batch, List<_Config> configs) async {
    final tables = {for (final c in configs) c.name: c};
    final remote = await _remoteBatches(tx, batch.checkpoint.feedId);
    final result = <String, _Dirty>{};
    for (final transaction in batch.transactions) {
      if (remote.contains(transaction.id)) continue;
      for (final event in transaction.events) {
        final c = tables[event.table];
        if (c == null) continue;
        for (final key in [event.oldKey, event.newKey]) {
          if (key == null) continue;
          final metadata = await _row(tx, c, key);
          if (transaction.id <= metadata.discard) continue;
          final identity = _identity(c, key);
          final dirty = result.putIfAbsent(identity, () => _Dirty(c, key));
          dirty.fields.addAll(event.changedColumns.where(c.columns.contains));
          if (event.kind == ChangeKind.insert ||
              event.kind == ChangeKind.update &&
                  c.key(event.oldKey!) != c.key(event.newKey!)) {
            dirty.full = true;
          }
          dirty.full |= metadata.full;
        }
      }
    }
    result.removeWhere((key, dirty) => dirty.fields.isEmpty);
    return result;
  }

  Future<SyncOperation?> _prepare(
          int maxMutations, int maxTransactions, int maxEvents) =>
      changes.transaction((tx) async {
        final state = await _state(tx);
        final old = await _outbox(tx);
        if (old != null) return old;
        final configs = await _configs(tx);
        final batch = await tx.readChanges(_consumer,
            maxTransactions: maxTransactions, maxEvents: maxEvents);
        final dirty = await _dirty(tx, batch, configs);
        if (dirty.length > maxMutations) {
          throw const SyncStateException(
              'Whole local batch exceeds maxMutations');
        }
        final mutations = <SyncMutation>[];
        for (final value in dirty.values) {
          final c = value.config;
          final row = await _source(tx, c, value.key);
          final metadata = await _row(tx, c, value.key);
          final full =
              value.full || metadata.version == null || metadata.tombstone;
          final patch = row == null
              ? null
              : {
                  for (final field in c.columns)
                    if (full ||
                        value.fields.contains(field) ||
                        c.keys.contains(field))
                      field: row[field]
                };
          mutations.add(SyncMutation(
              table: c.name,
              key: value.key,
              baseVersion: metadata.version,
              values: patch));
          if (metadata.full) await _putRow(tx, c, value.key, full: false);
        }
        final result =
            mutations.isEmpty ? null : await _enqueue(tx, state, mutations);
        await tx.acknowledge(_consumer, batch.checkpoint);
        // Origin markers are owned by this consumer only; other Changes consumers
        // still observe the original events independently.
        final markers =
            await tx.query('SELECT id,batch_id FROM _spsync_remote WHERE id>0');
        for (final marker in markers.rows) {
          if (_int(marker[1]) <= batch.checkpoint.batch) {
            await tx
                .execute('DELETE FROM _spsync_remote WHERE id=?', [marker[0]]);
          }
        }
        return result;
      });

  void _record(_Config c, SyncRecord record, {bool allowAbsent = false}) {
    if (record.version == BigInt.zero && allowAbsent && record.values == null) {
      c.key(record.key);
      return;
    }
    if (record.version < BigInt.one || record.version > _max) {
      throw const SyncProtocolException('Invalid server revision');
    }
    c.key(record.key);
    final values = record.values;
    if (values != null) {
      if (values.length != c.columns.length ||
          !c.columns.every(values.containsKey)) {
        throw const SyncProtocolException(
            'Remote records must include all registered columns');
      }
      if (c.key({for (final k in c.keys) k: values[k]}) != c.key(record.key)) {
        throw const SyncProtocolException('Record/key mismatch');
      }
      for (final value in values.values) {
        SyncCodec.value(value);
      }
    }
  }

  Future<bool> _pushReply(SyncOperation sent, SyncPushResult reply) =>
      changes.transaction((tx) async {
        final state = await _state(tx);
        final frozen = await _outbox(tx);
        if (frozen == null ||
            frozen.id != sent.id ||
            reply.operationId != frozen.id ||
            reply.records.length != frozen.mutations.length) {
          throw const SyncProtocolException(
              'Push outcome does not match frozen operation');
        }
        final configs = {for (final c in await _configs(tx)) c.name: c};
        final byKey = <String, SyncRecord>{};
        for (final record in reply.records) {
          final c = configs[record.table];
          if (c == null) {
            throw const SyncProtocolException('Unknown remote table');
          }
          _record(c, record, allowAbsent: !reply.accepted);
          if (byKey.putIfAbsent(_identity(c, record.key), () => record) !=
              record) {
            throw const SyncProtocolException('Duplicate push outcome');
          }
        }
        for (final mutation in frozen.mutations) {
          final c = configs[mutation.table]!;
          final remote = byKey[_identity(c, mutation.key)];
          if (remote == null) {
            throw const SyncProtocolException('Missing push outcome');
          }
          if (remote.version == BigInt.zero && mutation.baseVersion != null) {
            throw const SyncProtocolException(
                'Server forgot a known revision/tombstone');
          }
          if (mutation.baseVersion != null &&
              remote.version < mutation.baseVersion!) {
            throw const SyncProtocolException(
                'Server revision moved backwards');
          }
          if (reply.accepted) {
            if (mutation.baseVersion != null &&
                remote.version <= mutation.baseVersion!) {
              throw const SyncProtocolException(
                  'Accepted revision must increase');
            }
            if ((remote.values == null) != (mutation.values == null)) {
              throw const SyncProtocolException('Server changed mutation kind');
            }
            final patch = mutation.values;
            if (patch != null) {
              for (final entry in patch.entries) {
                if (jsonEncode(SyncCodec.value(remote.values![entry.key])) !=
                    jsonEncode(SyncCodec.value(entry.value))) {
                  throw const SyncProtocolException(
                      'Server canonicalization requires an explicit adapter policy');
                }
              }
            }
          }
        }
        if (!reply.accepted) {
          final id = await _allocate(tx, state);
          await tx.execute('INSERT INTO _spsync_conflicts VALUES(?,?,?)',
              [id, 'push', jsonEncode(reply.toJson())]);
          return false;
        }
        for (final remote in reply.records) {
          await _putRow(tx, configs[remote.table]!, remote.key,
              version: remote.version, tombstone: remote.values == null);
        }
        await tx.execute('DELETE FROM _spsync_outbox WHERE id>0');
        return true;
      });
}
