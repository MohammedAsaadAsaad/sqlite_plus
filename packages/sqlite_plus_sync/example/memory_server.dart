import 'dart:convert';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';

/// Development-only reference transport. Not an authenticated/durable server.
final class MemorySyncServer implements SyncTransport {
  final _rows = <String, Map<String, SyncRecord>>{};
  final _log = <String, List<List<SyncRecord>>>{};
  final _dedup = <String, (String, SyncPushResult)>{};
  var _version = BigInt.zero;
  int pushCalls = 0, applications = 0, pullCalls = 0;

  String _key(String table, Map<String, Object?> key) {
    final keys = key.keys.toList()..sort();
    return jsonEncode([
      table,
      SyncCodec.fields({for (final k in keys) k: key[k]})
    ]);
  }

  SyncRecord _copy(SyncRecord record) => SyncRecord.fromJson(record.toJson());

  @override
  Future<SyncPushResult> push(SyncOperation operation) async {
    pushCalls++;
    final wire = jsonEncode(operation.toJson());
    final identity = jsonEncode([operation.scope, operation.id]);
    final previous = _dedup[identity];
    if (previous != null) {
      if (previous.$1 != wire) {
        throw StateError('An operation ID was reused with another body');
      }
      return SyncPushResult.fromJson(previous.$2.toJson());
    }
    final rows = _rows.putIfAbsent(operation.scope, () => {});
    final current = <SyncRecord>[];
    final seen = <String>{};
    var accepted = true;
    for (final mutation in operation.mutations) {
      final key = _key(mutation.table, mutation.key);
      if (!seen.add(key)) throw StateError('Duplicate mutation key');
      final row = rows[key];
      if (row?.version != mutation.baseVersion) accepted = false;
      current.add(row ??
          SyncRecord(
              table: mutation.table,
              key: mutation.key,
              version: BigInt.zero,
              values: null));
    }
    final result = <SyncRecord>[];
    if (accepted) {
      for (final mutation in operation.mutations) {
        final key = _key(mutation.table, mutation.key);
        final patch = mutation.values;
        final values = patch == null ? null : {...?rows[key]?.values, ...patch};
        final record = SyncRecord(
            table: mutation.table,
            key: mutation.key,
            version: _version += BigInt.one,
            values: values);
        rows[key] = _copy(record);
        result.add(record);
      }
      _log
          .putIfAbsent(operation.scope, () => [])
          .add(result.map(_copy).toList());
      applications++;
    } else {
      result.addAll(current.map(_copy));
    }
    final reply = SyncPushResult(
        operationId: operation.id, accepted: accepted, records: result);
    _dedup[identity] = (wire, SyncPushResult.fromJson(reply.toJson()));
    return reply;
  }

  @override
  Future<SyncPullPage> pull(SyncPullRequest request) async {
    pullCalls++;
    final log = _log[request.scope] ?? [];
    var position = request.after == null ? 0 : int.parse(request.after!);
    if (position < 0 || position > log.length) {
      throw StateError('Cursor expired/invalid');
    }
    final result = <SyncRecord>[];
    while (position < log.length) {
      final group = log[position];
      if (result.length + group.length > request.limit) {
        if (result.isEmpty) {
          throw StateError('Server transaction exceeds page budget');
        }
        break;
      }
      result.addAll(group.map(_copy));
      position++;
    }
    return SyncPullPage(
        after: request.after,
        cursor: '$position',
        records: result,
        hasMore: position < log.length);
  }
}
