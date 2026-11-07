part of 'changes.dart';

extension ChangeConsumers on SqlitePlusChanges {
  void _validCheckpoint(_State state, ChangeCheckpoint checkpoint,
      {bool allowExpired = false}) {
    if (checkpoint.feedId != state.id ||
        checkpoint.batch.isNegative ||
        checkpoint.batch > state.head) {
      throw ArgumentError(
          'Checkpoint belongs to a different feed or an invalid position');
    }
    if (!allowExpired && checkpoint.batch < state.floor) {
      throw CheckpointExpired(checkpoint, state.at(state.floor));
    }
  }

  Future<List<Object?>> _consumerRow(String name) async {
    final rows = await database.query(
        'SELECT acked_batch,delivered_batch,id,feed_id FROM _spc_consumers NOT INDEXED WHERE name=?',
        [name]);
    if (rows.rows.length != 1) {
      throw const ChangeLogCorrupt('Missing or duplicate consumer');
    }
    final row = rows.rows.single;
    final ack = _integer(row[0]), delivered = _integer(row[1]);
    if (ack.isNegative ||
        delivered < ack ||
        row[3] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(row[3] as String)) {
      throw const ChangeLogCorrupt('Invalid consumer position');
    }
    return row;
  }

  Future<ChangeConsumer> consumer(
          {required String name,
          ChangeCheckpoint? startAt,
          bool resumeExisting = false}) =>
      _run(() async {
        if (name.isEmpty || name.contains('\u0000')) {
          throw ArgumentError('Consumer name is required');
        }
        await _verifySources();
        final state = await _state();
        final found = await database.query(
            'SELECT acked_batch FROM _spc_consumers NOT INDEXED WHERE name=?',
            [name]);
        if (found.rows.isEmpty) {
          final start = startAt ?? state.at(BigInt.zero);
          _validCheckpoint(state, start);
          await _atomic(() => database.execute(
              'INSERT INTO _spc_consumers(name,acked_batch,delivered_batch,feed_id) VALUES(?,?,?,?)',
              [name, start.batch, start.batch, state.id]));
        } else {
          final row = await _consumerRow(name);
          _validCheckpoint(state, state.at(_integer(row[0])),
              allowExpired: true);
          if (_integer(row[1]) > state.head) {
            throw const ChangeLogCorrupt('Consumer points beyond head');
          }
          if (startAt != null &&
              !resumeExisting &&
              (startAt.feedId != state.id || startAt.batch != row[0])) {
            throw StateError('Consumer already exists; use reset explicitly');
          }
        }
        return ChangeConsumer._(this, name);
      });

  Map<String, Object>? _decodeKey(Object? raw, _Source source) {
    if (raw == null) return null;
    try {
      final values = jsonDecode(raw as String) as List;
      if (values.length != source.keys.length) throw const FormatException();
      final result = <String, Object>{};
      for (var i = 0; i < values.length; i++) {
        final entry = values[i] as List;
        if (entry.length != 3 ||
            entry[0] != source.keys[i] ||
            entry[2] is! String ||
            !{'integer', 'text'}.contains(entry[1])) {
          throw const FormatException();
        }
        final text = entry[2] as String;
        if (entry[1] == 'integer') {
          final value = BigInt.parse(text);
          if (value < -(_maximum + BigInt.one) ||
              value > _maximum ||
              value.toString() != text) {
            throw const FormatException();
          }
          result[entry[0] as String] = value;
        } else {
          result[entry[0] as String] = text;
        }
      }
      return result;
    } on FormatException {
      throw const ChangeLogCorrupt('Malformed captured primary key');
    } on TypeError {
      throw const ChangeLogCorrupt('Malformed captured primary key');
    }
  }

  ChangeEvent _event(List<Object?> row, Map<BigInt, _Source> sources) {
    try {
      final source = sources[_integer(row[0])];
      if (source == null) throw const FormatException();
      final kind =
          ChangeKind.values.where((kind) => kind.name == row[1]).toList();
      if (kind.length != 1) throw const FormatException();
      final before = _decodeKey(row[2], source),
          after = _decodeKey(row[3], source);
      if ((kind.single == ChangeKind.insert &&
              (before != null || after == null)) ||
          (kind.single == ChangeKind.delete &&
              (before == null || after != null)) ||
          (kind.single == ChangeKind.update &&
              (before == null || after == null))) {
        throw const FormatException();
      }
      final changed = (jsonDecode(row[4] as String) as List)
          .where((v) => v != null)
          .cast<String>()
          .toList();
      if (changed.isEmpty ||
          changed.toSet().length != changed.length ||
          !changed.every(source.columns.contains)) {
        throw const FormatException();
      }
      return ChangeEvent(
          table: source.name,
          kind: kind.single,
          oldKey: before,
          newKey: after,
          changedColumns: changed);
    } on FormatException {
      throw const ChangeLogCorrupt('Malformed change event');
    } on TypeError {
      throw const ChangeLogCorrupt('Malformed change event');
    }
  }

  Future<ChangeBatch> _read(String name, int limit, int maxEvents) =>
      _run(() async {
        await _verifySources();
        return _readAt(name, await _state(), limit, maxEvents);
      });

  Future<ChangeBatch> _readAt(
      String name, _State state, int limit, int maxEvents,
      {bool inScope = false}) async {
    if (maxEvents < 1 || maxEvents > 1000000) {
      throw ArgumentError('maxEvents must be 1..1000000');
    }
    if (limit < 1 || limit > 1000) {
      throw ArgumentError('maxTransactions must be 1..1000');
    }
    final consumer = await _consumerRow(name);
    if (consumer[3] != state.id) {
      throw CheckpointExpired(
          ChangeCheckpoint(consumer[3] as String, _integer(consumer[0])),
          state.at(state.floor));
    }
    final ack = _integer(consumer[0]);
    _validCheckpoint(state, state.at(ack));
    if (_integer(consumer[1]) > state.head) {
      throw const ChangeLogCorrupt('Consumer points beyond head');
    }
    final batch = await _batches(state, ack, limit, maxEvents);
    final checkpoint = batch.checkpoint;
    if (checkpoint.batch > _integer(consumer[1])) {
      Future<void> delivered() async {
        await database.execute(
            'UPDATE _spc_consumers SET delivered_batch=? WHERE id=?',
            [checkpoint.batch, consumer[2]]);
      }

      if (inScope) {
        await delivered();
      } else {
        await _atomic(delivered);
      }
    }
    return batch;
  }

  Future<ChangeBatch> _batches(
      _State state, BigInt ack, int limit, int maxEvents) async {
    final sources = {for (final source in await _sources()) source.id: source};
    final batches = await database.browse(
        'SELECT id,event_count FROM _spc_batches WHERE id>? ORDER BY id LIMIT $limit',
        [ack]);
    final transactions = <ChangeTransaction>[];
    var next = ack + BigInt.one;
    var remaining = BigInt.from(maxEvents);
    for (final row in batches.rows) {
      final id = _integer(row[0]), count = _integer(row[1]);
      if (id != next || id > state.head || count < BigInt.one) {
        throw const ChangeLogCorrupt('Missing or invalid transaction metadata');
      }
      if (count > remaining) {
        if (transactions.isEmpty) {
          throw ChangeBatchTooLarge(id, count, maxEvents);
        }
        break;
      }
      remaining -= count;
      final events = await database.query(
          'SELECT source_id,kind,old_key,new_key,columns_json FROM _spc_events WHERE batch_id=? ORDER BY id',
          [id]);
      if (BigInt.from(events.rows.length) != count) {
        throw const ChangeLogCorrupt('Incomplete transaction events');
      }
      transactions.add(ChangeTransaction(
          id, [for (final event in events.rows) _event(event, sources)]));
      next = id + BigInt.one;
    }
    if (transactions.isEmpty && ack < state.head) {
      throw const ChangeLogCorrupt('Missing retained transactions');
    }
    final checkpoint =
        state.at(transactions.isEmpty ? ack : transactions.last.id);
    return ChangeBatch(checkpoint, transactions);
  }

  /// Stateless, read-only observation. Does not register a retention consumer.
  /// An expired position throws; observers of current state can reload fully.
  Future<ChangeBatch> readSince(ChangeCheckpoint checkpoint,
          {int maxTransactions = 1000, int maxEvents = 100000}) =>
      _run(() async {
        if (maxTransactions < 1 ||
            maxTransactions > 1000 ||
            maxEvents < 1 ||
            maxEvents > 1000000) {
          throw ArgumentError('Invalid transaction/event budgets');
        }
        await _verifySources();
        final state = await _state();
        _validCheckpoint(state, checkpoint);
        return _batches(state, checkpoint.batch, maxTransactions, maxEvents);
      });

  Future<void> _acknowledge(String name, ChangeCheckpoint checkpoint) =>
      _run(() async {
        final state = await _state();
        await _atomic(() => _acknowledgeAt(name, checkpoint, state));
      });

  Future<void> _acknowledgeAt(
      String name, ChangeCheckpoint checkpoint, _State state) async {
    _validCheckpoint(state, checkpoint);
    final row = await _consumerRow(name);
    if (row[3] != state.id) {
      throw CheckpointExpired(
          ChangeCheckpoint(row[3] as String, _integer(row[0])),
          state.at(state.floor));
    }
    _validCheckpoint(state, state.at(_integer(row[0])));
    if (_integer(row[1]) > state.head) {
      throw const ChangeLogCorrupt('Consumer points beyond head');
    }
    if (checkpoint.batch < _integer(row[0]) ||
        checkpoint.batch > _integer(row[1])) {
      throw ArgumentError(
          'Acknowledge a delivered position without moving backwards');
    }
    await database.execute('UPDATE _spc_consumers SET acked_batch=? WHERE id=?',
        [checkpoint.batch, row[2]]);
  }

  Future<void> _reset(String name, ChangeCheckpoint checkpoint) =>
      _run(() async {
        final state = await _state();
        _validCheckpoint(state, checkpoint);
        final row = await _consumerRow(name);
        await _atomic(() => database.execute(
            'UPDATE _spc_consumers SET acked_batch=?,delivered_batch=?,feed_id=? WHERE id=?',
            [checkpoint.batch, checkpoint.batch, state.id, row[2]]));
      });

  /// Deletes only the prefix acknowledged by every registered consumer.
  /// With no consumers it retains history. Does not shrink the physical file.
  Future<ChangeCheckpoint> pruneAcknowledged() => _run(() async {
        final state = await _state();
        final consumers = await database
            .query('SELECT acked_batch,feed_id FROM _spc_consumers');
        if (consumers.rows.isEmpty) return state.at(state.floor);
        var through = state.head;
        for (final row in consumers.rows) {
          if (row[1] != state.id) return state.at(state.floor);
          final ack = _integer(row[0]);
          if (ack.isNegative || ack > state.head) {
            throw const ChangeLogCorrupt('Invalid consumer position');
          }
          if (ack < through) through = ack;
        }
        if (through <= state.floor) return state.at(state.floor);
        await _prune(state, through);
        return state.at(through);
      });

  /// Explicit forced retention may expire lagging consumers. They must resnapshot
  /// and [ChangeConsumer.reset] before continuing; there is no silent skip.
  Future<void> pruneThrough(ChangeCheckpoint checkpoint,
          {bool expireLaggingConsumers = false}) =>
      _run(() async {
        final state = await _state();
        _validCheckpoint(state, checkpoint, allowExpired: true);
        if (checkpoint.batch <= state.floor) return;
        if (!expireLaggingConsumers) {
          final lagging = await database.query(
              'SELECT name FROM _spc_consumers WHERE acked_batch<? OR feed_id<>?',
              [checkpoint.batch, state.id]);
          if (lagging.rows.isNotEmpty) {
            throw StateError(
                'Retention is blocked by unacknowledged consumers');
          }
        }
        await _prune(state, checkpoint.batch);
      });

  Future<void> _prune(_State state, BigInt through) => _atomic(() async {
        await database
            .execute('DELETE FROM _spc_events WHERE batch_id<=?', [through]);
        for (var id = state.floor + BigInt.one;
            id <= through;
            id += BigInt.one) {
          await database.execute('DELETE FROM _spc_batches WHERE id=?', [id]);
        }
        await database.execute(
            'UPDATE _spc_state SET pruned_through=? WHERE id=1', [through]);
      });
}
