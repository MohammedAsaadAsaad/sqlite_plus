part of 'changes.dart';

/// DML-only scope. Await every operation. Use [savepoint] for recoverable errors.
final class ChangeWriter {
  ChangeWriter._(this._feed, this._state);
  final SqlitePlusChanges _feed;
  final _State _state;
  MutableSqliteDatabase get _db => _feed.database;
  bool _closed = false, _busy = false;
  Future<void>? _pending;
  Object? _error;
  StackTrace? _stack;
  int _savepoint = 0;

  void _available() {
    if (_closed || _busy || !_db.inTransaction) {
      throw StateError(
          'Await the current changes operation; scope may be closed');
    }
  }

  void _checkSql(String sql, bool read) {
    final tokens = SqlTokenizer.tokenize(sql);
    final allowed = read
        ? {'SELECT', 'WITH'}
        : {'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'WITH'};
    if (tokens.isEmpty ||
        !allowed.contains(tokens.first.keyword) ||
        tokens.any((token) =>
            token.kind == SqlTokenKind.identifier &&
            token.text.toLowerCase().startsWith('_spc_'))) {
      throw ArgumentError(
          'ChangeWriter accepts application DML/SELECT, not schema, transaction or reserved-metadata SQL');
    }
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _available();
    _busy = true;
    final result = Future<T>.sync(action);
    _pending = result.then<void>((_) {}, onError: (Object e, StackTrace s) {
      _error ??= e;
      _stack ??= s;
    });
    try {
      return await result;
    } finally {
      _busy = false;
    }
  }

  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    _checkSql(sql, false);
    return _operation(() => _db.execute(sql, parameters));
  }

  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    _checkSql(sql, true);
    return _operation(() => _db.query(sql, parameters));
  }

  /// Committed head before this producer scope started.
  ChangeCheckpoint get baseCheckpoint => _state.at(_state.head);

  void _consumer(ChangeConsumer consumer) {
    if (!identical(consumer._feed.database, _db)) {
      throw ArgumentError('Consumer belongs to another database');
    }
  }

  /// Source definitions verified at the start of this transaction.
  Future<List<ChangeSource>> sources() =>
      _operation(() async => List.unmodifiable([
            for (final source in await _feed._sources(enabledOnly: true))
              ChangeSource(source.name, source.keys, source.columns)
          ]));

  /// Read committed Changes inside this transaction, excluding its new events.
  Future<ChangeBatch> readChanges(ChangeConsumer consumer,
      {int maxTransactions = 100, int maxEvents = 1000}) {
    _consumer(consumer);
    return _operation(() => _feed._readAt(
        consumer.name, _state, maxTransactions, maxEvents,
        inScope: true));
  }

  /// Persist consumer progress atomically with this scope's application writes.
  Future<void> acknowledge(
      ChangeConsumer consumer, ChangeCheckpoint checkpoint) {
    _consumer(consumer);
    return _operation(
        () => _feed._acknowledgeAt(consumer.name, checkpoint, _state));
  }

  /// Pending batch identity, or null when this scope has captured no events yet.
  /// Allows application origin markers to commit with the captured events.
  Future<ChangeCheckpoint?> pendingCheckpoint() => _operation(() async {
        final rows = await _db.query(
            'SELECT count(*) FROM _spc_events WHERE batch_id=?', [_state.next]);
        return _integer(rows.rows.single.single) == BigInt.zero
            ? null
            : _state.at(_state.next);
      });

  /// Events captured so far in this scope, not yet published. Never includes
  /// older committed batches; a rollback/savepoint rollback discards them.
  Future<ChangeBatch> pendingChanges({int maxEvents = 1000000}) =>
      _operation(() async {
        if (maxEvents < 1 || maxEvents > 1000000) {
          throw ArgumentError('maxEvents must be 1..1000000');
        }
        final count = _integer((await _db.query(
                'SELECT count(*) FROM _spc_events WHERE batch_id=?',
                [_state.next]))
            .rows
            .single
            .single);
        if (count > BigInt.from(maxEvents)) {
          throw ChangeBatchTooLarge(_state.next, count, maxEvents);
        }
        if (count == BigInt.zero) return ChangeBatch(baseCheckpoint, const []);
        final sources = {
          for (final source in await _feed._sources()) source.id: source
        };
        final rows = await _db.query(
            'SELECT source_id,kind,old_key,new_key,columns_json FROM _spc_events WHERE batch_id=? ORDER BY id',
            [_state.next]);
        if (BigInt.from(rows.rows.length) != count) {
          throw const ChangeLogCorrupt('Incomplete pending batch');
        }
        return ChangeBatch(_state.at(_state.next), [
          ChangeTransaction(_state.next,
              [for (final row in rows.rows) _feed._event(row, sources)])
        ]);
      });

  Future<void> _finish() async {
    if (_pending != null) await _pending;
    _closed = true;
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
  }

  Future<void> _stop() async {
    if (_pending != null) await _pending;
    _closed = true;
  }

  Future<T> savepoint<T>(Future<T> Function(ChangeWriter child) action) async {
    _available();
    _busy = true;
    final child = ChangeWriter._(_feed, _state);
    final name = '_spc_save_${_savepoint++}';
    final result = () async {
      await _db.execute('SAVEPOINT $name');
      try {
        final value = await action(child);
        await child._finish();
        await _db.execute('RELEASE $name');
        return value;
      } catch (error, stack) {
        await child._stop();
        if (_db.inTransaction) {
          await _db.execute('ROLLBACK TO $name');
          await _db.execute('RELEASE $name');
        }
        Error.throwWithStackTrace(error, stack);
      }
    }();
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    try {
      return await result;
    } finally {
      _busy = false;
    }
  }
}
