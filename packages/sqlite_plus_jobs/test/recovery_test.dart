import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';
import 'package:test/test.dart';
import 'fault_storage.dart';

Future<MutableSqliteDatabase> open(FaultStorage data, FaultStorage log) async =>
    MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(data, log));
Future<List<List<String>>> state(MutableSqliteDatabase db) async {
  final tables =
      await db.query("SELECT name FROM sqlite_schema WHERE name='_spj_jobs'");
  if (tables.rows.isEmpty) return [];
  final result = await db.query(
      'SELECT id,queue,type,payload,state,attempts,lease_token IS NOT NULL,lease_until,error,finished_at FROM _spj_jobs ORDER BY id');
  final rows =
      result.rows.map((r) => r.map((v) => v.toString()).toList()).toList();
  final app =
      await db.query("SELECT name FROM sqlite_schema WHERE name='app_results'");
  if (app.rows.isNotEmpty) {
    rows.addAll((await db.query('SELECT id FROM app_results ORDER BY id'))
        .rows
        .map((r) => ['app', r.single.toString()]));
  }
  return rows;
}

void main() {
  test('uncertain commit poisons all jobs handles on that connection',
      () async {
    final seed = await openInMemory();
    final image = seed.exportImage();
    await seed.close();
    final faults = Faults();
    final data = FaultStorage(image, faults),
        log = FaultStorage(Uint8List(0), faults);
    final db = await open(data, log);
    final jobs = await SqlitePlusJobs.open(database: db);
    final second = await SqlitePlusJobs.open(database: db);
    faults.operations = 0;
    faults.failAfter = 1;
    await expectLater(jobs.enqueue('x'), throwsA(isA<PowerLoss>()));
    await expectLater(second.list(), throwsStateError);
    await expectLater(SqlitePlusJobs.open(database: db), throwsStateError);
    faults.failAfter = null;
    data.losePower();
    log.losePower();
    final recovered = await open(data, log);
    await SqlitePlusJobs.open(database: recovered);
    await recovered.close();
  });

  for (final mode in ['delete', 'persist']) {
    for (final immediate in [false, true]) {
      for (final phase in [
        'install',
        'enqueue',
        'claim',
        'complete',
        'fail',
        'expire',
        'prune'
      ]) {
        test('$phase power loss $mode immediate=$immediate', () async {
          final now = DateTime.utc(2026);
          final seed = await openInMemory();
          if (phase != 'install') {
            await seed
                .execute('CREATE TABLE app_results(id INTEGER PRIMARY KEY)');
            final queue =
                await SqlitePlusJobs.open(database: seed, clock: () => now);
            if (phase != 'enqueue') {
              await queue.enqueue('x', payload: {'n': 1}, maxAttempts: 1);
            }
            if (['expire', 'prune'].contains(phase)) {
              final lease = (await queue.claim(
                  leaseDuration: const Duration(milliseconds: 1)))!;
              if (phase == 'prune') await queue.complete(lease);
            }
          }
          final image = seed.exportImage();
          await seed.close();
          Future<(MutableSqliteDatabase, SqlitePlusJobs?, JobLease?)> setup(
              Faults f, FaultStorage data, FaultStorage log) async {
            final db = await open(data, log);
            await db.execute('PRAGMA journal_mode=$mode');
            final queue = phase == 'install'
                ? null
                : await SqlitePlusJobs.open(
                    database: db,
                    clock: () => now.add(phase == 'expire'
                        ? const Duration(milliseconds: 1)
                        : Duration.zero));
            final lease = phase == 'complete' || phase == 'fail'
                ? await queue!.claim()
                : null;
            f.operations = 0;
            return (db, queue, lease);
          }

          Future<void> action(MutableSqliteDatabase db, SqlitePlusJobs? queue,
              JobLease? lease) async {
            switch (phase) {
              case 'install':
                await SqlitePlusJobs.open(database: db);
                break;
              case 'enqueue':
                await queue!.transaction((tx) async {
                  await tx.execute('INSERT INTO app_results VALUES(1)');
                  await tx.enqueue('x',
                      payload: {'n': 1}, deduplicationKey: 'key');
                });
                break;
              case 'claim':
                await queue!.claim();
                break;
              case 'complete':
                await queue!.transaction((tx) async {
                  await tx.execute('INSERT INTO app_results VALUES(1)');
                  await tx.complete(lease!);
                });
                break;
              case 'fail':
                await queue!.fail(lease!, error: 'fault');
                break;
              case 'expire':
                await queue!.claim();
                break;
              case 'prune':
                await queue!
                    .prune(finishedBefore: now.add(const Duration(seconds: 1)));
                break;
            }
          }

          final f = Faults()..immediatePersistence = immediate;
          final data = FaultStorage(image, f),
              log = FaultStorage(Uint8List(0), f);
          final (db, queue, lease) = await setup(f, data, log);
          await action(db, queue, lease);
          final operations = f.operations, after = await state(db);
          expect(operations, greaterThan(0));
          await db.close();
          for (var point = 1; point <= operations; point++) {
            final faults = Faults()..immediatePersistence = immediate;
            final bytes = FaultStorage(image, faults),
                journal = FaultStorage(Uint8List(0), faults);
            final (victim, jobs, current) = await setup(faults, bytes, journal);
            final pre = await state(victim);
            faults.operations = 0;
            faults.failAfter = point;
            await expectLater(
                action(victim, jobs, current), throwsA(isA<PowerLoss>()));
            faults.failAfter = null;
            bytes.losePower();
            journal.losePower();
            // Never close victim: that could flush its volatile state.
            final recovered = await open(bytes, journal);
            expect(await state(recovered), anyOf(equals(pre), equals(after)),
                reason: 'fault $point/$operations');
            await SqlitePlusJobs.open(database: recovered);
            expect(
                (await recovered.query('PRAGMA integrity_check'))
                    .rows
                    .single
                    .single,
                'ok');
            await recovered.close();
          }
          print('$phase $mode immediate=$immediate: $operations fault points');
        });
      }
    }
  }
}
