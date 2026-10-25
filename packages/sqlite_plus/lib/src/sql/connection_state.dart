/// SQL-visible counters belonging to one connection, independent of snapshots.
/// Transactions roll back database pages; they do not roll back these counters.
final class SqlConnectionState {
  BigInt changes = BigInt.zero;
  BigInt totalChanges = BigInt.zero;
  BigInt lastInsertRowid = BigInt.zero;

  SqlStatementCounters beginStatement() => SqlStatementCounters._(this);

  (BigInt, BigInt) saveTrigger() => (changes, lastInsertRowid);

  void restoreTrigger((BigInt, BigInt) saved) {
    changes = saved.$1;
    lastInsertRowid = saved.$2;
  }
}

/// Direct row changes accumulate until the statement finishes. Nested trigger
/// statements publish their own totals as they finish, including changes made
/// by a trigger whose outer statement subsequently rolls back.
final class SqlStatementCounters {
  SqlStatementCounters._(this.connection);
  final SqlConnectionState connection;
  int _changes = 0;
  bool _finished = false;

  void changed({BigInt? insertedRowid}) {
    _changes++;
    if (insertedRowid != null) connection.lastInsertRowid = insertedRowid;
  }

  void finish({bool retainChanges = true}) {
    if (_finished) return;
    _finished = true;
    connection.changes = retainChanges ? BigInt.from(_changes) : BigInt.zero;
    if (retainChanges) connection.totalChanges += BigInt.from(_changes);
  }
}
