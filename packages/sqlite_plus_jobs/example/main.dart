import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';

Future<void> main() async {
  final db = await openInMemory();
  try {
    // A durable application uses its normal file/browser-backed connection here.
    await db.execute(
        'CREATE TABLE uploads(id INTEGER PRIMARY KEY,path TEXT NOT NULL,state TEXT NOT NULL)');
    final jobs = await SqlitePlusJobs.open(database: db);
    final created = await jobs.transaction((tx) async {
      await tx
          .execute("INSERT INTO uploads VALUES(1,?,'pending')", ['photo.jpg']);
      return tx.enqueue('upload',
          payload: {'uploadId': 1, 'path': 'photo.jpg'},
          deduplicationKey: 'upload:1');
    });
    final duplicate = await jobs.enqueue('upload',
        payload: {'uploadId': 1}, deduplicationKey: 'upload:1');
    if (duplicate.created || duplicate.id != created.id) {
      throw StateError('Dedup failed');
    }
    var externalUploads = 0;
    final worker = JobWorker(jobs, {
      'upload': (lease) async {
        final payload = lease.job.payload as Map;
        if (payload['path'] != 'photo.jpg') throw StateError('Payload');
        // Use a stable external idempotency key such as uploadId. A network
        // success followed by a crash before complete() may execute again.
        // Long operations should call jobs.renew(lease) before expiry, and stop
        // when it returns false. This example has no network side effect.
        externalUploads++;
        await jobs.transaction((tx) => tx.execute(
            "UPDATE uploads SET state='uploaded' WHERE id=?",
            [payload['uploadId']]));
      },
    });
    if (await worker.runOne() != JobRunOutcome.completed ||
        externalUploads != 1) {
      throw StateError('Worker');
    }
    if (await worker.runOne() != JobRunOutcome.idle) {
      throw StateError('Queue not empty');
    }
    if ((await jobs.get(created.id))!.state != JobState.succeeded) {
      throw StateError('Completion');
    }
    print(
        'Jobs assertions passed: atomic enqueue, deduplication and worker completion.');
  } finally {
    await db.close();
  }
}
