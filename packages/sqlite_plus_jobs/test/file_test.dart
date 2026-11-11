@TestOn('vm')
library;

import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';
import 'package:test/test.dart';

void main() {
  test('journal-backed files preserve lease and completion across close/reopen',
      () async {
    final directory = await Directory.systemTemp.createTemp('spj-file-');
    final path = '${directory.path}/queue.db',
        journalPath = '${directory.path}/queue.journal';
    final empty = await openInMemory();
    await File(path).writeAsBytes(empty.exportImage(), flush: true);
    await empty.close();
    await File(journalPath).writeAsBytes([], flush: true);
    Future<MutableSqliteDatabase> open() async =>
        MutableSqliteDatabase.fromJournalPager(await RollbackJournalPager.open(
            await DurableFileStorageBackend.openExclusive(path,
                directoryEntryIsDurable: true),
            await DurableFileStorageBackend.openExisting(journalPath,
                directoryEntryIsDurable: true)));
    var now = DateTime.utc(2026);
    final first = await open();
    BigInt? id;
    try {
      final queue =
          await SqlitePlusJobs.open(database: first, clock: () => now);
      id = (await queue.enqueue('upload',
              deduplicationKey: 'same', payload: {'file': 'photo.jpg'}))
          .id;
      await queue.claim(leaseDuration: const Duration(seconds: 1));
    } finally {
      await first.close();
    }
    final second = await open();
    try {
      final queue =
          await SqlitePlusJobs.open(database: second, clock: () => now);
      expect(await queue.claim(), null);
      now = now.add(const Duration(seconds: 1));
      final lease = (await queue.claim())!;
      expect(lease.job.id, id);
      expect(lease.job.attempts, 2);
      expect(await queue.complete(lease), true);
    } finally {
      await second.close();
    }
    final third = await open();
    try {
      final queue = await SqlitePlusJobs.open(database: third);
      expect((await queue.get(id))!.state, JobState.succeeded);
      expect((await queue.enqueue('upload', deduplicationKey: 'same')).created,
          false);
      expect((await third.query('PRAGMA integrity_check')).rows.single.single,
          'ok');
    } finally {
      await third.close();
      await directory.delete(recursive: true);
    }
  });
}
