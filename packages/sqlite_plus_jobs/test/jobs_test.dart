import 'dart:async';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusJobs jobs;
  late DateTime now;
  setUp(() async {
    now = DateTime.utc(2026);
    db = await openInMemory();
    jobs = await SqlitePlusJobs.open(database: db, clock: () => now);
  });
  tearDown(() async {
    await db.close();
  });

  test('queue-scoped dedup retains terminal keys until explicit prune',
      () async {
    final a = await jobs.enqueue('upload',
        payload: {'n': 1}, deduplicationKey: 'same');
    final duplicate = await jobs.enqueue('other', deduplicationKey: 'same');
    expect(duplicate.created, false);
    expect(duplicate.id, a.id);
    expect((await jobs.get(a.id))!.payload, {'n': 1});
    final other =
        await jobs.enqueue('upload', queue: 'other', deduplicationKey: 'same');
    expect(other.created, true);
    final lease = (await jobs.claim())!;
    expect(await jobs.complete(lease), true);
    expect((await jobs.enqueue('upload', deduplicationKey: 'same')).created,
        false);
    expect(await jobs.prune(finishedBefore: now), 0);
    now = now.add(const Duration(milliseconds: 1));
    expect(await jobs.prune(finishedBefore: now), 1);
    final b = await jobs.enqueue('upload', deduplicationKey: 'same');
    expect(b.created, true);
    expect(b.id, greaterThan(a.id));
    expect(await jobs.complete(lease), false);
  });
  test('payload is frozen before asynchronous enqueue and getter decodes fresh',
      () async {
    final body = {
      'n': <int>[1]
    };
    final pending = jobs.enqueue('x', payload: body);
    body['n']!.add(2);
    final job = (await jobs.get((await pending).id))!;
    expect(job.payload, {
      'n': [1]
    });
    (job.payload as Map)['n'].add(3);
    expect(job.payload, {
      'n': [1]
    });
  });
  test('priority, FIFO ID ties, delay, queue and accepted types', () async {
    final first = await jobs.enqueue('a');
    final second = await jobs.enqueue('a');
    await jobs.enqueue('b', priority: 100);
    await jobs.enqueue('a', queue: 'other', priority: 1000);
    final delayed = await jobs.enqueue('a',
        priority: 10, availableAt: now.add(const Duration(seconds: 10)));
    final high = await jobs.claim();
    expect(high!.job.type, 'b');
    expect((await jobs.claim(types: ['a']))!.job.id, first.id);
    expect((await jobs.claim(types: ['a']))!.job.id, second.id);
    expect(await jobs.claim(), null);
    now = now.add(const Duration(seconds: 10));
    expect((await jobs.claim())!.job.id, delayed.id);
  });
  test(
      'same-connection handles serialize competing claims and duplicate enqueue',
      () async {
    final other = await SqlitePlusJobs.open(database: db, clock: () => now);
    final added = await Future.wait(List.generate(
        10,
        (i) =>
            (i.isEven ? jobs : other).enqueue('x', deduplicationKey: 'same')));
    expect(added.where((x) => x.created).length, 1);
    final claims = await Future.wait(
        List.generate(10, (i) => (i.isEven ? jobs : other).claim()));
    expect(claims.whereType<JobLease>().length, 1);
    expect(await other.complete(claims.whereType<JobLease>().single), true);
  });
  test('strict expiry fences old worker, renew and completion', () async {
    await jobs.enqueue('x', maxAttempts: 3);
    final old = (await jobs.claim(leaseDuration: const Duration(seconds: 1)))!;
    now = now.add(const Duration(milliseconds: 500));
    expect(
        await jobs.renew(old, leaseDuration: const Duration(seconds: 1)), true);
    now = now.add(const Duration(milliseconds: 999));
    expect(await jobs.claim(), null);
    now = now.add(const Duration(milliseconds: 1));
    expect(await jobs.renew(old), false);
    expect(await jobs.complete(old), false);
    final next = (await jobs.claim())!;
    expect(next.job.attempts, 2);
    expect(await jobs.fail(old, error: 'stale'), false);
    expect(await jobs.complete(next), true);
    expect(await jobs.complete(next), false);
  });
  test('failure delay, maximum attempts and explicit retry', () async {
    final added = await jobs.enqueue('x',
        maxAttempts: 2, retryDelay: const Duration(seconds: 10));
    final first = (await jobs.claim())!;
    expect(await jobs.fail(first, error: 'network'), true);
    expect((await jobs.get(added.id))!.lastError, 'network');
    expect(await jobs.claim(), null);
    now = now.add(const Duration(seconds: 10));
    final second = (await jobs.claim())!;
    expect(second.job.attempts, 2);
    expect(await jobs.fail(second, error: 'again'), true);
    expect((await jobs.get(added.id))!.state, JobState.failed);
    expect(await jobs.claim(), null);
    expect(await jobs.retry(added.id), true);
    final third = (await jobs.claim())!;
    expect(third.job.attempts, 1);
    expect(await jobs.complete(second), false);
    expect(await jobs.complete(third), true);
    expect(await jobs.retry(added.id), false);
  });
  test('expired final attempt becomes terminal; cancelled worker cannot ack',
      () async {
    final a = await jobs.enqueue('x', maxAttempts: 1);
    final lease =
        (await jobs.claim(leaseDuration: const Duration(milliseconds: 1)))!;
    now = now.add(const Duration(milliseconds: 1));
    expect(await jobs.claim(), null);
    expect((await jobs.get(a.id))!.state, JobState.failed);
    expect(await jobs.complete(lease), false);
    expect(await jobs.retry(a.id), true);
    final next = (await jobs.claim())!;
    expect(await jobs.cancel(a.id), true);
    expect(await jobs.complete(next), false);
    expect(await jobs.renew(next), false);
    expect(await jobs.cancel(a.id), false);
    expect((await jobs.get(a.id))!.state, JobState.cancelled);
  });
  test(
      'application writes and enqueue are atomic; reentrancy and stale writer rejected',
      () async {
    await db.execute(
        'CREATE TABLE app(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>0))');
    JobsTransaction? retained;
    await expectLater(jobs.transaction((tx) async {
      retained = tx;
      await tx.enqueue('x');
      await tx.execute('INSERT INTO app VALUES(1,-1)');
    }), throwsA(isA<SqlException>()));
    expect(await jobs.list(), isEmpty);
    expect((await db.query('SELECT * FROM app')).rows, isEmpty);
    expect(() => retained!.enqueue('x'), throwsStateError);
    await expectLater(jobs.transaction((tx) async {
      await jobs.enqueue('x');
    }), throwsStateError);
    await jobs.transaction((tx) async {
      await tx.execute('INSERT INTO app VALUES(1,1)');
      await tx.enqueue('x');
    });
    expect((await jobs.list()).length, 1);
    await db.execute('BEGIN');
    await expectLater(jobs.claim(), throwsStateError);
    await db.execute('ROLLBACK');
  });
  test('transaction drains unawaited scoped writes and rolls back any failure',
      () async {
    await db
        .execute('CREATE TABLE app(id INTEGER PRIMARY KEY,n INTEGER NOT NULL)');
    await jobs.transaction((tx) async {
      unawaited(tx.enqueue('x'));
      unawaited(tx.enqueue('y'));
    });
    expect((await jobs.list()).length, 2);
    await expectLater(jobs.transaction((tx) async {
      unawaited(tx.enqueue('z'));
      unawaited(tx.execute('INSERT INTO app VALUES(1,NULL)'));
    }), throwsA(isA<SqlException>()));
    expect((await jobs.list()).length, 2);
  });
  test('bounded listing and pruning preserve pending jobs', () async {
    for (var i = 0; i < 4; i++) {
      await jobs.enqueue('x');
    }
    final page = await jobs.list(limit: 2);
    expect(page.length, 2);
    expect((await jobs.list(afterId: page.last.id, limit: 2)).length, 2);
    final a = (await jobs.claim())!, b = (await jobs.claim())!;
    await jobs.complete(a);
    await jobs.cancel(b.job.id);
    now = now.add(const Duration(seconds: 1));
    expect(await jobs.prune(finishedBefore: now, limit: 1), 1);
    expect((await jobs.list(state: JobState.queued)).length, 2);
    expect(await jobs.prune(finishedBefore: now), 1);
  });
  test('validation rejects bounds before writes', () async {
    for (final action in <void Function()>[
      () => jobs.enqueue(''),
      () => jobs.enqueue('x', queue: ''),
      () => jobs.enqueue('x', payload: double.nan),
      () => jobs.enqueue('x', payload: 'ا' * 65536),
      () => jobs.enqueue('x', maxAttempts: 0),
      () => jobs.enqueue('x', priority: 1000001),
      () => jobs.enqueue('x', deduplicationKey: ''),
      () => jobs.enqueue('x', retryDelay: const Duration(seconds: -1)),
      () => jobs.claim(leaseDuration: Duration.zero),
      () => jobs.claim(types: []),
      () => jobs.list(limit: 1001),
      () => jobs.list(limit: 0),
    ]) {
      expect(action, throwsA(isA<Object>()));
    }
    expect(await jobs.list(), isEmpty);
    await jobs.enqueue('x',
        payload: 'a' * 65534, maxAttempts: 100); // JSON quotes count.
    expect((await jobs.list()).length, 1);
    await jobs.transaction((tx) async {
      expect(() => tx.execute('COMMIT'), throwsArgumentError);
      expect(() => tx.execute('DELETE FROM _spj_jobs'), throwsArgumentError);
    });
  });
  test(
      'unsupported format and damaged reserved schema are not silently repaired',
      () async {
    await db.execute('UPDATE _spj_meta SET format=99');
    final image = db.exportImage();
    await expectLater(
        SqlitePlusJobs.open(database: db), throwsA(isA<JobsSchemaException>()));
    expect(db.exportImage(), image);
    await db.execute('UPDATE _spj_meta SET format=1');
    await db.execute('ALTER TABLE _spj_jobs ADD COLUMN unexpected INTEGER');
    await expectLater(
        SqlitePlusJobs.open(database: db), throwsA(isA<JobsSchemaException>()));
  });
  test('reopen retains payload, retries, leases and deduplication', () async {
    final a = await jobs.enqueue('x',
        payload: {'data': 'مرحبا'}, deduplicationKey: 'key');
    final old = (await jobs.claim(leaseDuration: const Duration(seconds: 1)))!;
    final recovered = await MutableSqliteDatabase.fromImage(db.exportImage());
    try {
      final queue =
          await SqlitePlusJobs.open(database: recovered, clock: () => now);
      expect(await queue.claim(), null);
      now = now.add(const Duration(seconds: 1));
      final next = (await queue.claim())!;
      expect(next.job.id, a.id);
      expect(next.job.attempts, 2);
      expect(next.job.payload, {'data': 'مرحبا'});
      expect(
          (await queue.enqueue('x', deduplicationKey: 'key')).created, false);
      expect(() => queue.complete(old), throwsArgumentError);
      expect(await queue.complete(next), true);
    } finally {
      await recovered.close();
    }
  });
  test(
      'worker filters unknown handlers, retries failures and reports lost lease',
      () async {
    await jobs.enqueue('unknown', priority: 100);
    final a =
        await jobs.enqueue('x', maxAttempts: 2, retryDelay: Duration.zero);
    var calls = 0;
    final worker = JobWorker(jobs, {
      'x': (lease) async {
        calls++;
        if (calls == 1) throw StateError('network');
      }
    });
    expect(await worker.runOne(), JobRunOutcome.retried);
    expect(await worker.runOne(), JobRunOutcome.completed);
    expect(await worker.runOne(), JobRunOutcome.idle);
    expect(calls, 2);
    expect((await jobs.get(a.id))!.state, JobState.succeeded);
    final b = await jobs.enqueue('expired');
    final slow = JobWorker(jobs, {
      'expired': (lease) async {
        now = now.add(const Duration(seconds: 31));
      }
    });
    expect(await slow.runOne(), JobRunOutcome.lostLease);
    expect((await jobs.get(b.id))!.state, JobState.running);
  });
  test('worker bounds UTF-8 diagnostics and final failure remains terminal',
      () async {
    final id = (await jobs.enqueue('x', maxAttempts: 1)).id;
    final worker = JobWorker(jobs, {
      'x': (lease) async {
        throw StateError('خطأ' * 3000);
      }
    });
    expect(await worker.runOne(), JobRunOutcome.failed);
    final row = (await jobs.get(id))!;
    expect(row.state, JobState.failed);
    expect(row.lastError!.length, lessThanOrEqualTo(4096));
    expect(await worker.runOne(), JobRunOutcome.idle);
  });
  test(
      'foreign leases, invalid errors, limits and negative submillisecond durations',
      () async {
    final other = await openInMemory();
    try {
      final second = await SqlitePlusJobs.open(database: other);
      await jobs.enqueue('x');
      final lease = (await jobs.claim())!;
      expect(() => second.renew(lease), throwsArgumentError);
      expect(() => jobs.fail(lease, error: ''), throwsArgumentError);
      expect(() => jobs.fail(lease, error: 'ا' * 4096), throwsArgumentError);
      expect(
          () => jobs.fail(lease,
              error: 'x', retryAfter: const Duration(microseconds: -1)),
          throwsArgumentError);
      expect(() => jobs.claim(leaseDuration: const Duration(days: 366)),
          throwsArgumentError);
      expect(() => jobs.enqueue('x', availableAt: DateTime.utc(1960)),
          throwsArgumentError);
      expect(await jobs.complete(lease), true);
    } finally {
      await other.close();
    }
  });
  test('atomic business result and completion roll back when lease is lost',
      () async {
    await db.execute('CREATE TABLE results(id INTEGER PRIMARY KEY)');
    await jobs.enqueue('x');
    final old =
        (await jobs.claim(leaseDuration: const Duration(milliseconds: 1)))!;
    now = now.add(const Duration(milliseconds: 1));
    final current = (await jobs.claim())!;
    await expectLater(jobs.transaction((tx) async {
      await tx.execute('INSERT INTO results VALUES(1)');
      await tx.complete(old);
    }), throwsA(isA<JobLeaseLostException>()));
    expect((await db.query('SELECT * FROM results')).rows, isEmpty);
    await jobs.transaction((tx) async {
      await tx.execute('INSERT INTO results VALUES(1)');
      await tx.complete(current);
    });
    expect((await jobs.get(current.job.id))!.state, JobState.succeeded);
    expect((await db.query('SELECT * FROM results')).rows.length, 1);
  });
  test(
      'persistent ID counter rejects corruption and fails atomically at exhaustion',
      () async {
    await jobs.enqueue('x');
    await db.execute('UPDATE _spj_meta SET next_id=1');
    await expectLater(
        SqlitePlusJobs.open(database: db), throwsA(isA<JobsSchemaException>()));
    await db.execute(
        'UPDATE _spj_meta SET next_id=?', [(BigInt.one << 63) - BigInt.one]);
    final image = db.exportImage();
    await expectLater(jobs.enqueue('y'), throwsStateError);
    expect(db.exportImage(), image);
    expect((await jobs.list()).length, 1);
  });
  test(
      'batch dedup snapshot preserves BINARY keys, existing rows and first payload',
      () async {
    final existing = await jobs.enqueue('old', deduplicationKey: 'key');
    await jobs.enqueue('old', queue: 'other', deduplicationKey: 'key');
    await jobs.transaction((tx) async {
      expect(
          (await tx.enqueue('new', deduplicationKey: 'key')).id, existing.id);
      final first =
          await tx.enqueue('x', payload: 1, deduplicationKey: 'a\u0000b');
      final second =
          await tx.enqueue('x', payload: 2, deduplicationKey: 'a\u0000b');
      expect(second.id, first.id);
      expect(second.created, false);
      expect((await tx.enqueue('x', deduplicationKey: 'Key')).created, true);
      expect((await tx.enqueue('x', deduplicationKey: 'é')).created, true);
      expect(
          (await tx.enqueue('x', deduplicationKey: 'e\u0301')).created, true);
    });
    final rows = await jobs.list();
    expect(rows.length, 5);
    expect(rows[1].payload, 1);
    expect(
        () => jobs.enqueue('x', deduplicationKey: String.fromCharCode(0xd800)),
        throwsArgumentError);
  });
  for (final encoding in [1, 2, 3]) {
    test(
        'scheduling metadata agrees with SQL ordering, filtering and clocks encoding=$encoding',
        () async {
      final engine = await openInMemory(encoding: encoding);
      addTearDown(engine.close);
      var time = DateTime.utc(2026);
      final queue =
          await SqlitePlusJobs.open(database: engine, clock: () => time);
      await queue.transaction((tx) async {
        for (var i = 0; i < 24; i++) {
          await tx.enqueue(['a', 'b', 'c', 'a\u0000x'][i % 4],
              queue: i % 7 == 0 ? 'other' : 'default',
              priority: i % 5 - 2,
              availableAt: time.add(Duration(milliseconds: i % 4)),
              maxAttempts: 3,
              retryDelay: Duration.zero);
        }
      });
      for (var i = 0; i < 24; i++) {
        time = time.add(const Duration(milliseconds: 2));
        final expected = await engine.query(
            "SELECT id FROM _spj_jobs WHERE queue=? AND attempts<max_attempts AND ((state='queued' AND available_at<=?) OR (state='running' AND lease_until<=?)) AND type IN (?,?) ORDER BY priority DESC,created_at,id LIMIT 1",
            [
              'default',
              time.millisecondsSinceEpoch,
              time.millisecondsSinceEpoch,
              'a',
              'a\u0000x'
            ]);
        final lease = await queue.claim(
            types: ['a', 'a\u0000x'],
            leaseDuration: const Duration(milliseconds: 1));
        expect(lease?.job.id,
            expected.rows.isEmpty ? null : expected.rows.single.single);
        if (lease != null) {
          switch (i % 4) {
            case 0:
              await queue.complete(lease);
              break;
            case 1:
              await queue.fail(lease, error: 'retry');
              break;
            case 2:
              await queue.renew(lease,
                  leaseDuration: const Duration(milliseconds: 1));
              break;
            case 3:
              await queue.cancel(lease.job.id);
              break;
          }
        }
        if (i == 5) await queue.enqueue('a', priority: 999);
      }
      expect((await engine.query('PRAGMA integrity_check')).rows.single.single,
          'ok');
    });
  }
}
