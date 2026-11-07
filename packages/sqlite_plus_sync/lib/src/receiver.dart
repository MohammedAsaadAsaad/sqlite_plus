part of 'sync.dart';

extension _Receiver on SqlitePlusSync {
  Future<Map<String, _Dirty>> _pending(
      ChangeWriter tx, List<_Config> configs) async {
    final pending = await tx.readChanges(_consumer,
        maxTransactions: 1000, maxEvents: 1000000);
    if (pending.checkpoint.batch != tx.baseCheckpoint.batch) {
      throw const SyncStateException(
          'Dirty scan incomplete; drain pending local transactions first');
    }
    return _dirty(tx, pending, configs);
  }

  Future<List<SyncRecord>> _fresh(
      ChangeWriter tx, List<SyncRecord> records, List<_Config> configs,
      {bool allowAbsent = false}) async {
    final tables = {for (final c in configs) c.name: c};
    final latest = <String, SyncRecord>{};
    for (final record in records) {
      final c = tables[record.table];
      if (c == null) {
        throw const SyncProtocolException('Unknown incoming table');
      }
      _record(c, record, allowAbsent: allowAbsent);
      final key = _identity(c, record.key);
      final previous = latest[key];
      if (previous != null && record.version <= previous.version) {
        throw const SyncProtocolException(
            'Duplicate/out-of-order incoming revisions');
      }
      latest[key] = record;
    }
    final result = <SyncRecord>[];
    for (final record in latest.values) {
      final local = await _row(tx, tables[record.table]!, record.key);
      if (allowAbsent ||
          local.version == null ||
          record.version > local.version!) {
        result.add(record);
      }
    }
    return result;
  }

  Future<void> _apply(ChangeWriter tx, _Config c, SyncRecord record) async {
    final key = record.key;
    final where = c.keys.map((k) => '${_quote(k)}=?').join(' AND ');
    final args = [for (final k in c.keys) key[k]];
    final values = record.values;
    if (values == null) {
      await tx.execute('DELETE FROM ${_quote(c.name)} WHERE $where', args);
    } else if (await _source(tx, c, key) == null) {
      await tx.execute(
          'INSERT INTO ${_quote(c.name)}(${c.columns.map(_quote).join(',')}) VALUES(${List.filled(c.columns.length, '?').join(',')})',
          [for (final k in c.columns) values[k]]);
    } else {
      final fields = c.columns.where((k) => !c.keys.contains(k)).toList();
      if (fields.isNotEmpty) {
        await tx.execute(
            'UPDATE ${_quote(c.name)} SET ${fields.map((k) => '${_quote(k)}=?').join(',')} WHERE $where',
            [for (final k in fields) values[k], ...args]);
      }
    }
  }

  Future<int> _pullPage(SyncPullRequest request, SyncPullPage page) =>
      changes.transaction((tx) async {
        final state = await _state(tx);
        if (request.after != state.cursor ||
            page.after != state.cursor ||
            page.records.length > request.limit ||
            page.cursor != null &&
                (page.cursor!.isEmpty || page.cursor!.length > 4096) ||
            (page.records.isNotEmpty || page.hasMore) &&
                (page.cursor == null || page.cursor == state.cursor)) {
          throw const SyncProtocolException(
              'Invalid/stalled pull cursor, echo or page budget');
        }
        if (state.cursor != null && page.cursor == null) {
          throw const SyncProtocolException('Cursor moved to null');
        }
        final configs = await _configs(tx);
        final fresh = await _fresh(tx, page.records, configs);
        if (fresh.isNotEmpty) {
          final dirty = await _pending(tx, configs);
          final tables = {for (final c in configs) c.name: c};
          if (fresh.any(
              (r) => dirty.containsKey(_identity(tables[r.table]!, r.key)))) {
            final id = await _allocate(tx, state);
            await tx.execute('INSERT INTO _spsync_conflicts VALUES(?,?,?)',
                [id, 'pull', jsonEncode(page.toJson())]);
            return -1;
          }
          for (final record in fresh) {
            final c = tables[record.table]!;
            await _apply(tx, c, record);
            await _putRow(tx, c, record.key,
                version: record.version, tombstone: record.values == null);
          }
          await _markRemote(tx, fresh);
        }
        await tx.execute(
            'UPDATE _spsync_state SET cursor=? WHERE id=1', [page.cursor]);
        return fresh.length;
      });

  Future<void> _resolve(String id, SyncResolution resolution) =>
      changes.transaction((tx) async {
        final state = await _state(tx);
        final conflict = await _conflict(tx);
        if (conflict == null ||
            id != '${state.replica}:${state.feed}:conflict:${conflict[0]}') {
          throw const SyncStateException(
              'Conflict no longer exists or belongs to another feed');
        }
        final payload = _json(conflict[2] as String);
        final push = conflict[1] == 'push';
        if (!push && conflict[1] != 'pull') {
          throw const SyncStateException('Malformed conflict kind');
        }
        if (!push && payload['after'] != state.cursor) {
          throw const SyncStateException('Conflict cursor changed');
        }
        final configs = await _configs(tx);
        final tables = {for (final c in configs) c.name: c};
        final records = [
          for (final value in payload['records'] as List)
            SyncRecord.fromJson((value as Map).cast<String, dynamic>())
        ];
        final fresh = await _fresh(tx, records, configs, allowAbsent: push);
        final dirty = await _pending(tx, configs);
        final outbox = await _outbox(tx);
        if (push && (outbox == null || outbox.id != payload['operationId'])) {
          throw const SyncStateException('Conflict/outbox identity mismatch');
        }
        final retry = <SyncMutation>[];
        final applied = <SyncRecord>[];
        for (final record in fresh) {
          final c = tables[record.table]!;
          final keep = resolution == SyncResolution.keepLocal &&
              (push || dirty.containsKey(_identity(c, record.key)));
          if (keep) {
            if (push) {
              retry.add(SyncMutation(
                  table: c.name,
                  key: record.key,
                  baseVersion:
                      record.version == BigInt.zero ? null : record.version,
                  values: await _source(tx, c, record.key)));
            }
            await _putRow(tx, c, record.key,
                version: record.version == BigInt.zero ? null : record.version,
                tombstone: record.values == null,
                full: !push);
          } else {
            await _apply(tx, c, record);
            applied.add(record);
            await _putRow(tx, c, record.key,
                version: record.version == BigInt.zero ? null : record.version,
                tombstone: record.values == null,
                discard: resolution == SyncResolution.acceptRemote
                    ? tx.baseCheckpoint.batch
                    : null,
                full: false);
          }
        }
        if (push) {
          await tx.execute('DELETE FROM _spsync_outbox WHERE id>0');
          if (retry.isNotEmpty) await _enqueue(tx, state, retry);
        } else {
          await tx.execute('UPDATE _spsync_state SET cursor=? WHERE id=1',
              [payload['cursor']]);
        }
        await _markRemote(tx, applied);
        await tx
            .execute('DELETE FROM _spsync_conflicts WHERE id=?', [conflict[0]]);
      });
}
