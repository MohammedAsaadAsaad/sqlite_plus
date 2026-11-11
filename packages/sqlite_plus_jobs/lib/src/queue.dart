part of '../sqlite_plus_jobs.dart';

const _definitions = <String, String>{
  '_spj_meta':
      'CREATE TABLE _spj_meta(id INTEGER PRIMARY KEY CHECK(id=1),format INTEGER NOT NULL,next_id INTEGER NOT NULL CHECK(next_id>0))',
  '_spj_jobs':
      "CREATE TABLE _spj_jobs(id INTEGER PRIMARY KEY,queue TEXT NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','failed','cancelled')),priority INTEGER NOT NULL,created_at INTEGER NOT NULL,available_at INTEGER NOT NULL,attempts INTEGER NOT NULL CHECK(attempts>=0 AND attempts<=max_attempts),max_attempts INTEGER NOT NULL CHECK(max_attempts>=1 AND max_attempts<=100),retry_ms INTEGER NOT NULL,lease_token TEXT,lease_until INTEGER,error TEXT,finished_at INTEGER,dedup_key TEXT,UNIQUE(queue,dedup_key),UNIQUE(queue,priority,created_at,id),UNIQUE(queue,type,id),CHECK((state='running' AND lease_token IS NOT NULL AND lease_until IS NOT NULL) OR (state<>'running' AND lease_token IS NULL AND lease_until IS NULL)),CHECK((state IN ('succeeded','failed','cancelled') AND finished_at IS NOT NULL) OR (state IN ('queued','running') AND finished_at IS NULL)))",
};
const _columns =
    'id,queue,type,payload,state,priority,created_at,available_at,attempts,max_attempts,retry_ms,lease_token,lease_until,error,finished_at';
final _jobZone = Object();

/// Opt-in queue over one exclusively loaned engine connection. Handles sharing
/// that SAME object serialize. Independent connections/processes are not covered.
final class SqlitePlusJobs {
  SqlitePlusJobs._(this.database, this._clock);
  final MutableSqliteDatabase database;
  final DateTime Function() _clock;
  static final _tails = Expando<Future<void>>();
  static final _poisoned = Expando<bool>();

  static Future<SqlitePlusJobs> open({
    required MutableSqliteDatabase database,
    DateTime Function()? clock,
  }) async {
    final jobs = SqlitePlusJobs._(database, clock ?? DateTime.now);
    await jobs._run(() async {
      final schema = await database.query(
          'SELECT name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL');
      final owned = schema.rows
          .where((r) =>
              (r[0] as String).toLowerCase().startsWith('_spj_') ||
              (r[1] as String).toLowerCase().startsWith('_spj_'))
          .toList();
      if (owned.isEmpty) {
        await jobs._atomic(() async {
          for (final ddl in _definitions.values) {
            await database.execute(ddl);
          }
          await database.execute('INSERT INTO _spj_meta VALUES(1,1,1)');
        });
      } else if (owned.length != _definitions.length ||
          owned.any((r) => _definitions[r[0]] != r[2])) {
        throw const JobsSchemaException(
            'Missing, changed or unknown reserved schema; no automatic repair');
      }
      final automatic = await database.query(
          "SELECT name,sql FROM sqlite_schema WHERE type='index' AND tbl_name='_spj_jobs'");
      final expected = {
        for (var i = 1; i <= 3; i++) 'sqlite_autoindex__spj_jobs_$i'
      };
      if (automatic.rows.length != 3 ||
          automatic.rows.any((r) => !expected.contains(r[0]) || r[1] != null)) {
        throw const JobsSchemaException('Missing or changed queue indexes');
      }
      final state =
          await database.query('SELECT id,format,next_id FROM _spj_meta');
      if (state.rows.length != 1 ||
          state.rows.single[0] != BigInt.one ||
          state.rows.single[1] != BigInt.one ||
          state.rows.single[2] is! BigInt ||
          (state.rows.single[2] as BigInt) < BigInt.one ||
          (state.rows.single[2] as BigInt) > (BigInt.one << 63) - BigInt.one) {
        throw const JobsSchemaException('Unsupported queue format');
      }
      final maximum = (await database.query('SELECT MAX(id) FROM _spj_jobs'))
          .rows
          .single
          .single;
      if (maximum != null &&
          (maximum as BigInt) >= (state.rows.single[2] as BigInt)) {
        throw const JobsSchemaException('Invalid next job ID');
      }
    });
    return jobs;
  }

  BigInt? _nextId;
  Map<(String, String), BigInt>? _dedupCache;
  Future<BigInt> _allocate() async {
    _nextId ??=
        (await database.query('SELECT next_id FROM _spj_meta WHERE id=1'))
            .rows
            .single
            .single as BigInt;
    final id = _nextId!;
    if (id >= (BigInt.one << 63) - BigInt.one) {
      throw StateError('Job ID range exhausted');
    }
    _nextId = id + BigInt.one;
    return id;
  }

  int _now() => _time(_clock());
  Future<T> _run<T>(Future<T> Function() action) {
    if (Zone.current[_jobZone] == database) {
      return Future.error(
          StateError('Reentrant jobs call; use JobsTransaction'));
    }
    final next = (_tails[database] ?? Future<void>.value()).then((_) {
      if (_poisoned[database] == true) {
        throw StateError(
            'Uncertain transaction; reopen a recovered connection');
      }
      if (database.inTransaction) {
        throw StateError(
            'Jobs requires exclusive connection use outside caller transactions');
      }
      return runZoned(action, zoneValues: {_jobZone: database});
    });
    _tails[database] =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<T> _atomic<T>(Future<T> Function() action) async {
    await database.execute('BEGIN IMMEDIATE');
    _nextId = null;
    _dedupCache = null;
    var committing = false;
    try {
      final value = await action();
      if (!database.inTransaction) {
        throw StateError('Transaction ended unexpectedly');
      }
      if (_nextId != null) {
        await database
            .execute('UPDATE _spj_meta SET next_id=? WHERE id=1', [_nextId]);
      }
      committing = true;
      await database.execute('COMMIT');
      return value;
    } catch (error, stack) {
      if (committing) _poisoned[database] = true;
      if (database.inTransaction) {
        try {
          await database.execute('ROLLBACK');
        } catch (_) {
          _poisoned[database] = true;
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _nextId = null;
      _dedupCache = null;
    }
  }

  /// Atomically combine application DML with enqueue. The scoped writer expires
  /// when the callback ends; finish/await every operation inside the callback.
  Future<T> transaction<T>(Future<T> Function(JobsTransaction tx) action) =>
      _run(() => _atomic(() async {
            final writer = JobsTransaction._(this);
            try {
              final result = await action(writer);
              writer._active = false;
              await writer._tail;
              if (writer._error != null) {
                Error.throwWithStackTrace(writer._error!, writer._stack!);
              }
              return result;
            } finally {
              writer._active = false;
              await writer._tail;
            }
          }));

  Future<EnqueueResult> enqueue(
    String type, {
    Object? payload,
    String queue = 'default',
    String? deduplicationKey,
    int priority = 0,
    DateTime? availableAt,
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 30),
  }) {
    final input = _input(type, payload, queue, deduplicationKey, priority,
        availableAt, maxAttempts, retryDelay);
    return _run(() => _atomic(() => _enqueue(input)));
  }

  _JobInput _input(String type, Object? payload, String queue, String? dedup,
      int priority, DateTime? available, int maxAttempts, Duration retry) {
    _text(type, 128, 'type');
    _text(queue, 128, 'queue');
    if (dedup != null) _text(dedup, 256, 'deduplicationKey');
    if (priority < -1000000 || priority > 1000000) throw RangeError('priority');
    if (maxAttempts < 1 || maxAttempts > 100) throw RangeError('maxAttempts');
    final json = jsonEncode(payload);
    if (utf8.encode(json).length > 65536) {
      throw RangeError('Payload exceeds 64KiB JSON');
    }
    return (
      type: type,
      payload: json,
      queue: queue,
      dedup: dedup,
      priority: priority,
      available: available == null ? null : _time(available),
      attempts: maxAttempts,
      retry: _duration(retry, 'retryDelay', allowZero: true)
    );
  }

  Future<EnqueueResult> _enqueue(_JobInput input, {bool batch = false}) async {
    if (input.dedup != null) {
      BigInt? existing;
      if (batch) {
        if (_dedupCache == null) {
          final rows = await database.query(
              'SELECT queue,dedup_key,id FROM _spj_jobs WHERE dedup_key IS NOT NULL');
          _dedupCache = {
            for (final row in rows.rows)
              (row[0] as String, row[1] as String): row[2] as BigInt
          };
        }
        existing = _dedupCache![(input.queue, input.dedup!)];
      } else {
        final found = await database.query(
            'SELECT id FROM _spj_jobs WHERE queue=? AND dedup_key=?',
            [input.queue, input.dedup]);
        if (found.rows.isNotEmpty) {
          existing = found.rows.single.single as BigInt;
        }
      }
      if (existing != null) return EnqueueResult(existing, created: false);
    }
    final now = _now();
    final id = await _allocate();
    final result = await database.execute(
        "INSERT INTO _spj_jobs(id,queue,type,payload,state,priority,created_at,available_at,attempts,max_attempts,retry_ms,dedup_key) VALUES(?,?,?,?,'queued',?,?,?,0,?,?,?) RETURNING id",
        [
          id,
          input.queue,
          input.type,
          input.payload,
          input.priority,
          now,
          input.available ?? now,
          input.attempts,
          input.retry,
          input.dedup
        ]);
    if (_dedupCache != null && input.dedup != null) {
      _dedupCache![(input.queue, input.dedup!)] = id;
    }
    return EnqueueResult(result.returning!.rows.single.single as BigInt,
        created: true);
  }

  Future<Job?> get(BigInt id) => _run(() async {
        final result = await database
            .query('SELECT $_columns FROM _spj_jobs WHERE id=?', [id]);
        return result.rows.isEmpty ? null : Job._(result.rows.single);
      });

  /// Bounded ID-keyset listing, including terminal jobs until explicit pruning.
  Future<List<Job>> list(
      {String queue = 'default',
      JobState? state,
      BigInt? afterId,
      int limit = 100}) {
    _text(queue, 128, 'queue');
    _limit(limit);
    return _run(() async {
      final result = await database.query(
          'SELECT $_columns FROM _spj_jobs WHERE queue=? AND id>?${state == null ? '' : ' AND state=?'} ORDER BY id LIMIT ?',
          [
            queue,
            afterId ?? BigInt.zero,
            if (state != null) state.name,
            limit
          ]);
      return List.unmodifiable(result.rows.map(Job._));
    });
  }

  /// Claims ready or expired jobs by priority DESC, then creation/id ASC.
  /// A crash consumes an attempt. Final expired attempts become failed.
  Future<JobLease?> claim(
      {String queue = 'default',
      Duration leaseDuration = const Duration(seconds: 30),
      List<String>? types}) {
    _text(queue, 128, 'queue');
    final duration = _duration(leaseDuration, 'leaseDuration');
    final accepted = types == null ? null : List<String>.of(types);
    if (accepted != null) {
      if (accepted.isEmpty || accepted.length > 32) {
        throw RangeError('types must contain 1..32 names');
      }
      for (final type in accepted) {
        _text(type, 128, 'type');
      }
    }
    return _run(() => _atomic(() async {
          final now = _now();
          final until = _later(now, duration);
          // This simple equality read uses the engine's live-row path. Project
          // scheduling metadata only; payloads are fetched for the claimed row.
          // The snapshot is local to this transaction, never retained as truth.
          final rows = await database.query(
              'SELECT id,type,state,priority,created_at,available_at,attempts,max_attempts,lease_until FROM _spj_jobs WHERE queue=?',
              [queue]);
          final time = BigInt.from(now);
          var exhausted = false;
          List<Object?>? selected;
          for (final row in rows.rows) {
            final state = row[2] as String;
            final attempts = row[6] as BigInt, maximum = row[7] as BigInt;
            final expired = state == 'running' && (row[8] as BigInt) <= time;
            if (expired && attempts >= maximum) exhausted = true;
            if (attempts >= maximum ||
                !(state == 'queued' && (row[5] as BigInt) <= time || expired) ||
                accepted != null && !accepted.contains(row[1])) {
              continue;
            }
            final best = selected;
            if (best == null ||
                (row[3] as BigInt) > (best[3] as BigInt) ||
                row[3] == best[3] &&
                    ((row[4] as BigInt) < (best[4] as BigInt) ||
                        row[4] == best[4] &&
                            (row[0] as BigInt) < (best[0] as BigInt))) {
              selected = row;
            }
          }
          if (exhausted) {
            await database.execute(
                "UPDATE _spj_jobs SET state='failed',lease_token=NULL,lease_until=NULL,error='Lease expired after final attempt',finished_at=? WHERE queue=? AND state='running' AND lease_until<=? AND attempts>=max_attempts",
                [now, queue, now]);
          }
          if (selected == null) return null;
          final id = selected[0];
          final random = Random.secure();
          final token = List.generate(24,
                  (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
              .join();
          final updated = await database.execute(
              "UPDATE _spj_jobs SET state='running',attempts=attempts+1,lease_token=?,lease_until=?,finished_at=NULL WHERE id=? RETURNING $_columns",
              [token, until, id]);
          return JobLease._(
              Job._(updated.returning!.rows.single), token, database);
        }));
  }

  void _lease(JobLease lease) {
    if (!identical(lease._database, database)) {
      throw ArgumentError('Lease belongs to another database');
    }
  }

  Future<bool> renew(JobLease lease,
      {Duration leaseDuration = const Duration(seconds: 30)}) {
    _lease(lease);
    final duration = _duration(leaseDuration, 'leaseDuration');
    return _run(() => _atomic(() async {
          final now = _now();
          final result = await database.execute(
              "UPDATE _spj_jobs SET lease_until=? WHERE id=? AND state='running' AND lease_token=? AND lease_until>?",
              [_later(now, duration), lease.job.id, lease._token, now]);
          return result.changes == 1;
        }));
  }

  Future<bool> complete(JobLease lease) => _finish(lease, null, null);
  Future<bool> fail(JobLease lease,
      {required String error, Duration? retryAfter}) {
    _text(error, 4096, 'error');
    if (retryAfter != null) {
      _duration(retryAfter, 'retryAfter', allowZero: true);
    }
    return _finish(lease, error, retryAfter);
  }

  Future<bool> _finish(JobLease lease, String? error, Duration? retry) {
    _lease(lease);
    return _run(() => _atomic(() async {
          final now = _now();
          final retrying =
              error != null && lease.job.attempts < lease.job.maxAttempts;
          final state = error == null
              ? 'succeeded'
              : retrying
                  ? 'queued'
                  : 'failed';
          final available = retrying
              ? _later(now, (retry ?? lease.job.retryDelay).inMilliseconds)
              : now;
          final result = await database.execute(
              "UPDATE _spj_jobs SET state=?,available_at=?,lease_token=NULL,lease_until=NULL,error=?,finished_at=? WHERE id=? AND state='running' AND lease_token=? AND lease_until>?",
              [
                state,
                available,
                error,
                retrying ? null : now,
                lease.job.id,
                lease._token,
                now
              ]);
          return result.changes == 1;
        }));
  }

  /// Stops future attempts; cannot undo an already-running external side effect.
  Future<bool> cancel(BigInt id) => _run(() => _atomic(() async {
        final result = await database.execute(
            "UPDATE _spj_jobs SET state='cancelled',lease_token=NULL,lease_until=NULL,finished_at=? WHERE id=? AND state IN ('queued','running')",
            [_now(), id]);
        return result.changes == 1;
      }));

  /// Explicitly retry a failed/cancelled job, resetting its attempt budget.
  Future<bool> retry(BigInt id) => _run(() => _atomic(() async {
        final result = await database.execute(
            "UPDATE _spj_jobs SET state='queued',attempts=0,available_at=?,lease_token=NULL,lease_until=NULL,error=NULL,finished_at=NULL WHERE id=? AND state IN ('failed','cancelled')",
            [_now(), id]);
        return result.changes == 1;
      }));

  /// Delete up to [limit] terminal rows, releasing their dedup keys. No VACUUM.
  Future<int> prune(
      {required DateTime finishedBefore,
      String queue = 'default',
      int limit = 100}) {
    _text(queue, 128, 'queue');
    _limit(limit);
    final cutoff = _time(finishedBefore);
    return _run(() => _atomic(() async {
          final ids = await database.query(
              "SELECT id FROM _spj_jobs WHERE queue=? AND state IN ('succeeded','failed','cancelled') AND finished_at<? ORDER BY id LIMIT ?",
              [queue, cutoff, limit]);
          if (ids.rows.isEmpty) return 0;
          final result = await database.execute(
              'DELETE FROM _spj_jobs WHERE id IN (${List.filled(ids.rows.length, '?').join(',')})',
              ids.rows.map((r) => r.single).toList());
          return result.changes;
        }));
  }
}

void _limit(int limit) {
  if (limit < 1 || limit > 1000) throw RangeError('limit must be 1..1000');
}

typedef _JobInput = ({
  String type,
  String payload,
  String queue,
  String? dedup,
  int priority,
  int? available,
  int attempts,
  int retry
});

final class JobsTransaction {
  JobsTransaction._(this._jobs);
  final SqlitePlusJobs _jobs;
  bool _active = true;
  Future<void> _tail = Future<void>.value();
  Object? _error;
  StackTrace? _stack;
  Future<T> _submit<T>(Future<T> Function() action) {
    _check();
    final result = _tail.then((_) {
      if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
      return action();
    });
    _tail =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      _error ??= error;
      _stack ??= stack;
    });
    return result;
  }

  void _check() {
    if (!_active || Zone.current[_jobZone] != _jobs.database) {
      throw StateError('JobsTransaction scope has ended');
    }
  }

  Future<EnqueueResult> enqueue(String type,
      {Object? payload,
      String queue = 'default',
      String? deduplicationKey,
      int priority = 0,
      DateTime? availableAt,
      int maxAttempts = 3,
      Duration retryDelay = const Duration(seconds: 30)}) {
    _check();
    final input = _jobs._input(type, payload, queue, deduplicationKey, priority,
        availableAt, maxAttempts, retryDelay);
    return _submit(() => _jobs._enqueue(input, batch: true));
  }

  /// Atomically persist application results and acknowledge a manually claimed
  /// job. Throws on lost lease, rolling back the entire surrounding transaction.
  /// Use this with manual claim, not JobWorker's automatic acknowledgement.
  Future<void> complete(JobLease lease) {
    _check();
    _jobs._lease(lease);
    return _submit(() async {
      final now = _jobs._now();
      final result = await _jobs.database.execute(
          "UPDATE _spj_jobs SET state='succeeded',available_at=?,lease_token=NULL,lease_until=NULL,error=NULL,finished_at=? WHERE id=? AND state='running' AND lease_token=? AND lease_until>?",
          [now, now, lease.job.id, lease._token, now]);
      if (result.changes != 1) throw const JobLeaseLostException();
    });
  }

  /// Application DML only; transaction control/schema/reserved names are rejected.
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    _check();
    if (!RegExp(r'^\s*(INSERT|UPDATE|DELETE|REPLACE)\b', caseSensitive: false)
            .hasMatch(sql) ||
        sql.toLowerCase().contains('_spj_')) {
      throw ArgumentError('Only application DML is allowed');
    }
    final args = List<Object?>.of(parameters);
    return _submit(() => _jobs.database.execute(sql, args));
  }
}
