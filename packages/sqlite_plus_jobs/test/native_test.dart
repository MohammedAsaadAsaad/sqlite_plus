@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';
import 'package:test/test.dart';

const projection =
    'id,queue,type,payload,state,priority,created_at,available_at,attempts,max_attempts,retry_ms,lease_token IS NOT NULL AS leased,lease_until,error,finished_at,dedup_key';
void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test('native state transitions and cross-open integrity encoding=$encoding',
        () async {
      final version =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
      expect(version.exitCode, 0);
      expect(version.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final dir = await Directory.systemTemp.createTemp('spj-native-');
      final db = await openInMemory(encoding: encoding);
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      var now = DateTime.utc(2026);
      final jobs = await SqlitePlusJobs.open(database: db, clock: () => now);
      final path = '${dir.path}/native.db';
      await File(path).writeAsBytes(db.exportImage());
      Future<void> compare([String? sql]) async {
        if (sql != null) {
          final update = await Process.run(cli, [path, sql]);
          expect(update.exitCode, 0, reason: update.stderr.toString());
        }
        final native = await Process.run(cli,
            ['-json', path, 'SELECT $projection FROM _spj_jobs ORDER BY id']);
        expect(native.exitCode, 0, reason: native.stderr.toString());
        final rows =
            await db.query('SELECT $projection FROM _spj_jobs ORDER BY id');
        final expected = native.stdout.toString().trim().isEmpty
            ? []
            : (jsonDecode(native.stdout.toString()) as List)
                .map((r) => (r as Map).values.toList())
                .toList();
        expect(
            rows.rows
                .map((r) => r.map((v) => v is BigInt ? v.toInt() : v).toList())
                .toList(),
            expected);
        final meta = await Process.run(
            cli, ['-json', path, 'SELECT next_id FROM _spj_meta']);
        final actualMeta = (await db.query('SELECT next_id FROM _spj_meta'))
            .rows
            .single
            .single as BigInt;
        expect((jsonDecode(meta.stdout.toString()) as List).single['next_id'],
            actualMeta.toInt());
        final exported = '${dir.path}/current.db';
        await File(exported).writeAsBytes(db.exportImage());
        final integrity =
            await Process.run(cli, [exported, 'PRAGMA integrity_check']);
        expect(integrity.exitCode, 0, reason: integrity.stderr.toString());
        expect(integrity.stdout.toString().trim(), 'ok');
      }

      final ms = now.millisecondsSinceEpoch;
      final a = await jobs.enqueue('upload',
          payload: {'name': 'صورة'}, deduplicationKey: 'a', maxAttempts: 2);
      await compare(
          "INSERT INTO _spj_jobs(queue,type,payload,state,priority,created_at,available_at,attempts,max_attempts,retry_ms,dedup_key) VALUES('default','upload','{\"name\":\"صورة\"}','queued',0,$ms,$ms,0,2,30000,'a'); UPDATE _spj_meta SET next_id=2;");
      expect(
          (await jobs.enqueue('upload', deduplicationKey: 'a')).created, false);
      await compare();
      final first =
          (await jobs.claim(leaseDuration: const Duration(seconds: 1)))!;
      await compare(
          "UPDATE _spj_jobs SET state='running',attempts=attempts+1,lease_token='native',lease_until=${ms + 1000} WHERE id=${a.id};");
      expect(await jobs.renew(first, leaseDuration: const Duration(seconds: 2)),
          true);
      await compare(
          'UPDATE _spj_jobs SET lease_until=${ms + 2000} WHERE id=${a.id}');
      expect(
          await jobs.fail(first,
              error: 'network', retryAfter: const Duration(seconds: 1)),
          true);
      await compare(
          "UPDATE _spj_jobs SET state='queued',available_at=${ms + 1000},lease_token=NULL,lease_until=NULL,error='network' WHERE id=${a.id};");
      expect(await jobs.claim(), null);
      now = now.add(const Duration(seconds: 1));
      final second =
          (await jobs.claim(leaseDuration: const Duration(milliseconds: 1)))!;
      await compare(
          "UPDATE _spj_jobs SET state='running',attempts=attempts+1,lease_token='native2',lease_until=${ms + 1001} WHERE id=${a.id};");
      now = now.add(const Duration(milliseconds: 1));
      expect(await jobs.complete(second), false);
      expect(await jobs.claim(), null);
      await compare(
          "UPDATE _spj_jobs SET state='failed',lease_token=NULL,lease_until=NULL,error='Lease expired after final attempt',finished_at=${ms + 1001} WHERE id=${a.id};");
      expect(await jobs.retry(a.id), true);
      await compare(
          "UPDATE _spj_jobs SET state='queued',attempts=0,available_at=${ms + 1001},error=NULL,finished_at=NULL WHERE id=${a.id};");
      final finalLease = (await jobs.claim())!;
      await compare(
          "UPDATE _spj_jobs SET state='running',attempts=1,lease_token='native3',lease_until=${ms + 31001} WHERE id=${a.id}");
      await jobs.transaction((tx) => tx.complete(finalLease));
      await compare(
          "UPDATE _spj_jobs SET state='succeeded',lease_token=NULL,lease_until=NULL,error=NULL,finished_at=${ms + 1001} WHERE id=${a.id}");
      final b = await jobs.enqueue('cancel');
      expect(b.id, BigInt.from(2));
      await compare(
          "INSERT INTO _spj_jobs(id,queue,type,payload,state,priority,created_at,available_at,attempts,max_attempts,retry_ms) VALUES(${b.id},'default','cancel','null','queued',0,${ms + 1001},${ms + 1001},0,3,30000); UPDATE _spj_meta SET next_id=3");
      expect(await jobs.cancel(b.id), true);
      await compare(
          "UPDATE _spj_jobs SET state='cancelled',finished_at=${ms + 1001} WHERE id=${b.id}");
      expect(
          await jobs.prune(
              finishedBefore: now.add(const Duration(milliseconds: 1))),
          2);
      await compare('DELETE FROM _spj_jobs');
    });
  }
}
