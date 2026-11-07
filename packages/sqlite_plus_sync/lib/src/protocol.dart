import 'dart:convert';
import 'dart:typed_data';

Map<String, Object?> _copy(Map<String, Object?> source) => Map.unmodifiable({
      for (final entry in source.entries)
        entry.key: entry.value is Uint8List
            ? Uint8List.fromList(entry.value as Uint8List)
            : entry.value is int
                ? BigInt.from(entry.value as int)
                : entry.value
    });

/// Typed wire encoding; integer values are decimal strings on every platform.
abstract final class SyncCodec {
  static Object value(Object? value) {
    if (value == null) return ['null'];
    if (value is int) value = BigInt.from(value);
    if (value is BigInt) {
      if (value < -(BigInt.one << 63) || value >= BigInt.one << 63) {
        throw ArgumentError('Integer exceeds signed64');
      }
      return ['integer', value.toString()];
    }
    if (value is String) return ['text', value];
    if (value is Uint8List) return ['blob', base64Encode(value)];
    if (value is double && value.isFinite) return ['real', value];
    throw ArgumentError('Expected a finite SQL value');
  }

  static Object? decodeValue(Object? raw) {
    if (raw is! List || raw.isEmpty) throw const FormatException('SQL value');
    if (raw.length == 1 && raw[0] == 'null') return null;
    if (raw.length != 2) throw const FormatException('SQL value width');
    switch (raw[0]) {
      case 'integer':
        final result = BigInt.parse(raw[1] as String);
        if (result.toString() != raw[1]) throw const FormatException('Integer');
        value(result);
        return result;
      case 'text':
        return raw[1] as String;
      case 'blob':
        return base64Decode(raw[1] as String);
      case 'real':
        final result = (raw[1] as num).toDouble();
        if (!result.isFinite) throw const FormatException('Finite real');
        return result;
      default:
        throw const FormatException('SQL type');
    }
  }

  static Map<String, Object> fields(Map<String, Object?> values) =>
      {for (final entry in values.entries) entry.key: value(entry.value)};
  static Map<String, Object?> decodeFields(Object? raw) => {
        for (final entry in (raw as Map).entries)
          entry.key as String: decodeValue(entry.value)
      };
}

final class SyncMutation {
  SyncMutation(
      {required this.table,
      required Map<String, Object?> key,
      required this.baseVersion,
      Map<String, Object?>? values})
      : _key = _copy(key),
        _values = values == null ? null : _copy(values);
  final String table;
  final BigInt? baseVersion;
  final Map<String, Object?> _key;
  final Map<String, Object?>? _values;
  Map<String, Object?> get key => _copy(_key);

  /// Null is a deletion; otherwise a patch (full row for a new key).
  Map<String, Object?>? get values => _values == null ? null : _copy(_values);
  Map<String, Object?> toJson() => {
        'table': table,
        'key': SyncCodec.fields(_key),
        'baseVersion': baseVersion?.toString(),
        'values': _values == null ? null : SyncCodec.fields(_values),
      };
  factory SyncMutation.fromJson(Map<String, dynamic> json) => SyncMutation(
        table: json['table'] as String,
        key: SyncCodec.decodeFields(json['key']),
        baseVersion: json['baseVersion'] == null
            ? null
            : BigInt.parse(json['baseVersion'] as String),
        values: json['values'] == null
            ? null
            : SyncCodec.decodeFields(json['values']),
      );
}

final class SyncOperation {
  SyncOperation(
      {required this.id,
      required this.scope,
      required Iterable<SyncMutation> mutations})
      : mutations = List.unmodifiable(mutations);
  final String id, scope;
  final List<SyncMutation> mutations;
  Map<String, Object?> toJson() => {
        'id': id,
        'scope': scope,
        'mutations': mutations.map((m) => m.toJson()).toList()
      };
  factory SyncOperation.fromJson(Map<String, dynamic> json) => SyncOperation(
        id: json['id'] as String,
        scope: json['scope'] as String,
        mutations: [
          for (final raw in json['mutations'] as List)
            SyncMutation.fromJson((raw as Map).cast<String, dynamic>())
        ],
      );
}

final class SyncRecord {
  SyncRecord(
      {required this.table,
      required Map<String, Object?> key,
      required this.version,
      Map<String, Object?>? values})
      : _key = _copy(key),
        _values = values == null ? null : _copy(values);
  final String table;
  final BigInt version;
  final Map<String, Object?> _key;
  final Map<String, Object?>? _values;
  Map<String, Object?> get key => _copy(_key);

  /// Full registered row fields, or null for a retained server tombstone.
  Map<String, Object?>? get values => _values == null ? null : _copy(_values);
  Map<String, Object?> toJson() => {
        'table': table,
        'key': SyncCodec.fields(_key),
        'version': version.toString(),
        'values': _values == null ? null : SyncCodec.fields(_values)
      };
  factory SyncRecord.fromJson(Map<String, dynamic> json) => SyncRecord(
        table: json['table'] as String,
        key: SyncCodec.decodeFields(json['key']),
        version: BigInt.parse(json['version'] as String),
        values: json['values'] == null
            ? null
            : SyncCodec.decodeFields(json['values']),
      );
}

final class SyncPushResult {
  SyncPushResult(
      {required this.operationId,
      required this.accepted,
      required Iterable<SyncRecord> records})
      : records = List.unmodifiable(records);
  final String operationId;

  /// False means the entire operation was rejected without server writes.
  final bool accepted;

  /// Exactly one current snapshot per mutation, for success and rejection.
  final List<SyncRecord> records;
  Map<String, Object?> toJson() => {
        'operationId': operationId,
        'accepted': accepted,
        'records': records.map((r) => r.toJson()).toList()
      };
  factory SyncPushResult.fromJson(Map<String, dynamic> json) => SyncPushResult(
          operationId: json['operationId'] as String,
          accepted: json['accepted'] as bool,
          records: [
            for (final raw in json['records'] as List)
              SyncRecord.fromJson((raw as Map).cast<String, dynamic>())
          ]);
}

final class SyncPullRequest {
  const SyncPullRequest(
      {required this.scope, required this.after, required this.limit});
  final String scope;
  final String? after;
  final int limit;
}

final class SyncPullPage {
  SyncPullPage(
      {required this.after,
      required this.cursor,
      required Iterable<SyncRecord> records,
      this.hasMore = false})
      : records = List.unmodifiable(records);
  final String? after, cursor;
  final List<SyncRecord> records;
  final bool hasMore;
  Map<String, Object?> toJson() => {
        'after': after,
        'cursor': cursor,
        'records': records.map((r) => r.toJson()).toList(),
        'hasMore': hasMore
      };
  factory SyncPullPage.fromJson(Map<String, dynamic> json) => SyncPullPage(
          after: json['after'] as String?,
          cursor: json['cursor'] as String?,
          hasMore: json['hasMore'] as bool,
          records: [
            for (final raw in json['records'] as List)
              SyncRecord.fromJson((raw as Map).cast<String, dynamic>())
          ]);
}

/// Server must deduplicate operation IDs (including the payload), atomically
/// compare/apply every mutation, and return increasing revisions/tombstones.
abstract interface class SyncTransport {
  Future<SyncPushResult> push(SyncOperation operation);
  Future<SyncPullPage> pull(SyncPullRequest request);
}

enum SyncResolution { keepLocal, acceptRemote }

final class SyncConflict {
  SyncConflict(
      {required this.id,
      required this.direction,
      required Iterable<SyncRecord> remote})
      : remote = List.unmodifiable(remote);
  final String id;

  /// 'push' or 'pull'. Resolution applies to this complete rejected group/page.
  final String direction;
  final List<SyncRecord> remote;
}

final class SyncResult {
  const SyncResult(
      {this.pushed = 0,
      this.pulled = 0,
      this.hasMore = false,
      this.conflicts = 0});
  final int pushed, pulled, conflicts;
  final bool hasMore;
}

final class SyncProtocolException implements Exception {
  const SyncProtocolException(this.message);
  final String message;
  @override
  String toString() => 'SyncProtocolException: $message';
}

final class SyncStateException implements Exception {
  const SyncStateException(this.message);
  final String message;
  @override
  String toString() => 'SyncStateException: $message';
}
