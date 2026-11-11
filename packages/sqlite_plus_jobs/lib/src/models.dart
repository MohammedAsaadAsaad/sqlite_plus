part of '../sqlite_plus_jobs.dart';

enum JobState { queued, running, succeeded, failed, cancelled }

/// Snapshot. Decode [payloadJson] on demand; mutating a decoded value cannot
/// modify the persisted job. Integer IDs are scoped to this database.
final class Job {
  Job._(List<Object?> row)
      : id = row[0] as BigInt,
        queue = row[1] as String,
        type = row[2] as String,
        payloadJson = row[3] as String,
        state = JobState.values.byName(row[4] as String),
        priority = (row[5] as BigInt).toInt(),
        createdAt = _date(row[6]),
        availableAt = _date(row[7]),
        attempts = (row[8] as BigInt).toInt(),
        maxAttempts = (row[9] as BigInt).toInt(),
        retryDelay = Duration(milliseconds: (row[10] as BigInt).toInt()),
        leaseUntil = row[12] == null ? null : _date(row[12]),
        lastError = row[13] as String?,
        finishedAt = row[14] == null ? null : _date(row[14]);
  final BigInt id;
  final String queue, type, payloadJson;
  final JobState state;
  final int priority, attempts, maxAttempts;
  final DateTime createdAt, availableAt;
  final Duration retryDelay;
  final DateTime? leaseUntil, finishedAt;
  final String? lastError;
  Object? get payload => jsonDecode(payloadJson);
}

final class EnqueueResult {
  const EnqueueResult(this.id, {required this.created});
  final BigInt id;
  final bool created;
}

/// Capability for one attempt. Only the queue which issued it may use it.
final class JobLease {
  JobLease._(this.job, this._token, this._database);
  final Job job;
  final String _token;
  final MutableSqliteDatabase _database;
}

final class JobsSchemaException implements Exception {
  const JobsSchemaException(this.message);
  final String message;
  @override
  String toString() => 'JobsSchemaException: $message';
}

DateTime _date(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch((value as BigInt).toInt(), isUtc: true);

const _maxTime = 8640000000000000;
void _text(String value, int maxBytes, String label) {
  if (value.isEmpty ||
      utf8.encode(value).length > maxBytes ||
      utf8.decode(utf8.encode(value)) != value) {
    throw ArgumentError.value(
        value, label, 'Must contain 1..$maxBytes UTF-8 bytes');
  }
}

int _duration(Duration value, String label, {bool allowZero = false}) {
  final ms = value.inMilliseconds;
  if (value.isNegative || ms < (allowZero ? 0 : 1) || ms > 31536000000) {
    throw ArgumentError.value(
        value, label, 'Must fit milliseconds, at most 365 days');
  }
  return ms;
}

int _time(DateTime date) {
  final value = date.millisecondsSinceEpoch;
  if (value < 0 || value > _maxTime) {
    throw ArgumentError('Unsupported timestamp');
  }
  return value;
}

int _later(int now, int delay) {
  if (now + delay > _maxTime) throw ArgumentError('Timestamp overflow');
  return now + delay;
}

/// A scoped completion lost its lease. The surrounding jobs transaction rolls
/// back application writes together with the attempted completion.
final class JobLeaseLostException implements Exception {
  const JobLeaseLostException();
  @override
  String toString() =>
      'JobLeaseLostException: lease is expired, replaced or terminal';
}
