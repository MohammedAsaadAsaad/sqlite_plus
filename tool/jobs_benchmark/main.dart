import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';

Future<void> main(List<String> args) async {
  final count = int.parse(args[0]);
  final mode = args[1];
  if (count < 1 || count > 10000 || !['batch', 'individual'].contains(mode))
    throw ArgumentError('count/mode');
  final db = await openInMemory();
  final now = DateTime.utc(2026);
  try {
    final base = db.exportImage().length;
    final clock = Stopwatch()..start();
    final jobs = await SqlitePlusJobs.open(database: db, clock: () => now);
    final install = clock.elapsedMicroseconds,
        installed = db.exportImage().length;
    clock
      ..reset()
      ..start();
    if (mode == 'batch') {
      await jobs.transaction((tx) async {
        for (var i = 0; i < count; i++) {
          await tx.enqueue('upload',
              payload: {'n': i}, deduplicationKey: 'item$i');
        }
      });
    } else {
      for (var i = 0; i < count; i++) {
        await jobs.enqueue('upload',
            payload: {'n': i}, deduplicationKey: 'item$i');
      }
    }
    final enqueue = clock.elapsedMicroseconds,
        enqueuedBytes = db.exportImage().length;
    clock
      ..reset()
      ..start();
    for (var i = 0; i < 100; i++) {
      final duplicate =
          await jobs.enqueue('upload', deduplicationKey: 'item${i % count}');
      if (duplicate.created) throw StateError('Dedup');
    }
    final duplicates = clock.elapsedMicroseconds;
    stderr.writeln(
        'rows=$count mode=$mode enqueue_us=$enqueue duplicate_100_us=$duplicates');
    clock
      ..reset()
      ..start();
    final operations =
        args.length > 2 ? int.parse(args[2]) : (count < 100 ? count : 100);
    if (operations < 1 || operations > count) throw ArgumentError('processed');
    for (var i = 0; i < operations; i++) {
      final lease = (await jobs.claim())!;
      if ((lease.job.payload as Map)['n'] != i || lease.job.attempts != 1)
        throw StateError('Claim order');
      if (!await jobs.complete(lease)) throw StateError('Completion');
    }
    clock.stop();
    final process = clock.elapsedMicroseconds;
    final rows = (await db.query(
            'SELECT id,payload,state,attempts FROM _spj_jobs ORDER BY id'))
        .rows;
    if (rows.length != count) throw StateError('Count');
    for (var i = 0; i < count; i++) {
      if (rows[i][2] != (i < operations ? 'succeeded' : 'queued'))
        throw StateError('State');
    }
    final image = db.exportImage();
    final logical = jsonEncode(
        rows.map((r) => r.map((v) => v.toString()).toList()).toList());
    print(jsonEncode({
      'rows': count,
      'mode': mode,
      'install_us': install,
      'enqueue_us': enqueue,
      'duplicate_100_us': duplicates,
      'claim_complete_us': process,
      'processed': operations,
      'base_bytes': base,
      'installed_bytes': installed,
      'enqueued_bytes': enqueuedBytes,
      'final_bytes': image.length,
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
  }
}
