import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';

Future<void> main(List<String> args) async {
  final count = int.parse(args[0]), operations = int.parse(args[1]);
  if (count < 1 || count > 10000 || operations < 1 || operations > count)
    throw ArgumentError('counts');
  final fileBacked = args.length > 2 && args[2] == 'file';
  Directory? directory;
  final MutableSqliteDatabase db;
  if (fileBacked) {
    directory = await Directory.systemTemp.createTemp('jobs-perf-');
    final initial = await openInMemory();
    final dataPath = '${directory.path}/queue.db',
        logPath = '${directory.path}/queue.journal';
    await File(dataPath).writeAsBytes(initial.exportImage(), flush: true);
    await initial.close();
    await File(logPath).writeAsBytes([], flush: true);
    // Existing-file benchmark fixture, not an OS power-loss/directory-sync test.
    db = await MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(
            await DurableFileStorageBackend.openExclusive(dataPath,
                directoryEntryIsDurable: true),
            await DurableFileStorageBackend.openExisting(logPath,
                directoryEntryIsDurable: true)));
  } else {
    db = await openInMemory();
  }
  try {
    final jobs = await SqlitePlusJobs.open(
        database: db, clock: () => DateTime.utc(2026));
    final seed = Stopwatch()..start();
    await jobs.transaction((tx) async {
      for (var i = 0; i < count; i++) {
        await tx.enqueue('upload',
            payload: {'n': i}, deduplicationKey: 'item$i');
      }
    });
    seed.stop();
    // Normalize starting image materialization in both variants.
    final base = db.exportImage().length;
    final total = Stopwatch()..start();
    var claim = 0, complete = 0;
    for (var i = 0; i < operations; i++) {
      final phase = Stopwatch()..start();
      final lease = (await jobs.claim())!;
      claim += phase.elapsedMicroseconds;
      if (lease.job.id != BigInt.from(i + 1) ||
          lease.job.attempts != 1 ||
          (lease.job.payload as Map)['n'] != i) throw StateError('Claim');
      phase
        ..reset()
        ..start();
      if (!await jobs.complete(lease)) throw StateError('Lease');
      complete += phase.elapsedMicroseconds;
    }
    total.stop();
    final rows = (await db.query(
            'SELECT id,payload,state,attempts FROM _spj_jobs ORDER BY id'))
        .rows;
    if (rows.length != count) throw StateError('Count');
    for (var i = 0; i < count; i++) {
      if (rows[i][0] != BigInt.from(i + 1) ||
          rows[i][2] != (i < operations ? 'succeeded' : 'queued') ||
          rows[i][3] != BigInt.from(i < operations ? 1 : 0))
        throw StateError('Final rows');
    }
    final image = db.exportImage();
    final logical = jsonEncode(
        rows.map((r) => r.map((v) => v.toString()).toList()).toList());
    print(jsonEncode({
      'storage': fileBacked ? 'file' : 'memory',
      'rows': count,
      'processed': operations,
      'seed_us': seed.elapsedMicroseconds,
      'claim_us': claim,
      'complete_us': complete,
      'total_us': total.elapsedMicroseconds,
      'base_bytes': base,
      'final_bytes': image.length,
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
    await directory?.delete(recursive: true);
  }
}
