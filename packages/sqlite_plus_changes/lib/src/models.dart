part of 'changes.dart';

/// A durable position in one feed. Integers serialize as strings on every target.
final class ChangeCheckpoint {
  const ChangeCheckpoint(this.feedId, this.batch);
  final String feedId;
  final BigInt batch;
  String encode() => jsonEncode({'feed': feedId, 'batch': batch.toString()});
  factory ChangeCheckpoint.decode(String value) {
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      final id = data['feed'] as String;
      final batch = BigInt.parse(data['batch'] as String);
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || batch.isNegative) {
        throw const FormatException('Invalid changes checkpoint');
      }
      return ChangeCheckpoint(id, batch);
    } on TypeError {
      throw const FormatException('Invalid changes checkpoint');
    }
  }
}

enum ChangeKind { insert, update, delete }

final class ChangeEvent {
  ChangeEvent(
      {required this.table,
      required this.kind,
      required Map<String, Object>? oldKey,
      required Map<String, Object>? newKey,
      required List<String> changedColumns})
      : oldKey = oldKey == null ? null : Map.unmodifiable(oldKey),
        newKey = newKey == null ? null : Map.unmodifiable(newKey),
        changedColumns = List.unmodifiable(changedColumns);
  final String table;
  final ChangeKind kind;
  final Map<String, Object>? oldKey;
  final Map<String, Object>? newKey;
  final List<String> changedColumns;
  Map<String, Object> get key => newKey ?? oldKey!;
}

final class ChangeTransaction {
  ChangeTransaction(this.id, List<ChangeEvent> events)
      : events = List.unmodifiable(events);
  final BigInt id;
  final List<ChangeEvent> events;
}

final class ChangeBatch {
  ChangeBatch(this.checkpoint, List<ChangeTransaction> transactions)
      : transactions = List.unmodifiable(transactions);
  final ChangeCheckpoint checkpoint;
  final List<ChangeTransaction> transactions;
  Iterable<ChangeEvent> get events => transactions.expand((t) => t.events);

  /// Deduplicated invalidation keys, including both sides of a key change.
  /// Does not collapse or mutate the transaction/event history.
  List<ChangeKey> affectedKeys() {
    final seen = <String>{};
    final result = <ChangeKey>[];
    for (final event in events) {
      for (final key in [event.oldKey, event.newKey]) {
        if (key == null) continue;
        final identity = jsonEncode([
          event.table,
          [
            for (final entry in key.entries)
              [
                entry.key,
                entry.value is BigInt ? 'integer' : 'text',
                entry.value.toString()
              ]
          ]
        ]);
        if (seen.add(identity)) result.add(ChangeKey(event.table, key));
      }
    }
    return List.unmodifiable(result);
  }
}

final class ChangeKey {
  ChangeKey(this.table, Map<String, Object> key) : key = Map.unmodifiable(key);
  final String table;
  final Map<String, Object> key;
}

final class CheckpointExpired implements Exception {
  const CheckpointExpired(this.requested, this.earliest);
  final ChangeCheckpoint requested;
  final ChangeCheckpoint earliest;
  @override
  String toString() => 'CheckpointExpired: resnapshot and reset the consumer';
}

final class ChangeLogCorrupt implements Exception {
  const ChangeLogCorrupt(this.message);
  final String message;
  @override
  String toString() => 'ChangeLogCorrupt: $message';
}

/// Context returned by [SqlitePlusChanges.consumer]. Acknowledgment is explicit.
final class ChangeConsumer {
  ChangeConsumer._(this._feed, this.name);
  final SqlitePlusChanges _feed;
  final String name;
  Future<ChangeBatch> read({int maxTransactions = 100, int maxEvents = 1000}) =>
      _feed._read(name, maxTransactions, maxEvents);
  Future<void> acknowledge(ChangeCheckpoint checkpoint) =>
      _feed._acknowledge(name, checkpoint);
  Future<void> reset(ChangeCheckpoint checkpoint) =>
      _feed._reset(name, checkpoint);
}

final class _Source {
  _Source(
      this.id, this.name, this.keys, this.columns, this.schema, this.triggers);
  final BigInt id;
  final String name;
  final List<String> keys, columns;
  final String schema;
  final Map<String, String> triggers;
}

final class _State {
  _State(this.id, this.next, this.floor);
  final String id;
  final BigInt next, floor;
  BigInt get head => next - BigInt.one;
  ChangeCheckpoint at(BigInt value) => ChangeCheckpoint(id, value);
}

/// A transaction is never split silently. Retry with an explicit larger budget.
final class ChangeBatchTooLarge implements Exception {
  const ChangeBatchTooLarge(this.transactionId, this.eventCount, this.limit);
  final BigInt transactionId, eventCount;
  final int limit;
  @override
  String toString() =>
      'ChangeBatchTooLarge: transaction $transactionId has $eventCount events; limit=$limit';
}

/// Verified definition of a currently tracked source.
final class ChangeSource {
  ChangeSource(
      this.table, Iterable<String> primaryKey, Iterable<String> columns)
      : primaryKey = List.unmodifiable(primaryKey),
        columns = List.unmodifiable(columns);
  final String table;
  final List<String> primaryKey, columns;
}

/// In-memory hint delivered only after a successful commit. The log, not this
/// non-durable stream, remains authoritative. Reset means reread current state.
final class ChangeNotification {
  const ChangeNotification(this.checkpoint, {this.reset = false});
  final ChangeCheckpoint checkpoint;
  final bool reset;
}
