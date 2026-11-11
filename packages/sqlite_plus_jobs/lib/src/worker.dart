part of '../sqlite_plus_jobs.dart';

typedef JobHandler = Future<void> Function(JobLease lease);

enum JobRunOutcome { idle, completed, retried, failed, lostLease }

/// Explicit execution, without polling or OS background scheduling. Handler work
/// runs outside transactions. Long handlers must renew their lease themselves.
final class JobWorker {
  JobWorker(this.jobs, Map<String, JobHandler> handlers,
      {this.queue = 'default',
      this.leaseDuration = const Duration(seconds: 30)})
      : handlers = Map.unmodifiable(handlers) {
    _text(queue, 128, 'queue');
    _duration(leaseDuration, 'leaseDuration');
    if (handlers.isEmpty || handlers.length > 32) {
      throw RangeError('handlers must contain 1..32 types');
    }
    for (final type in handlers.keys) {
      _text(type, 128, 'type');
    }
  }
  final SqlitePlusJobs jobs;
  final Map<String, JobHandler> handlers;
  final String queue;
  final Duration leaseDuration;

  Future<JobRunOutcome> runOne() async {
    final lease = await jobs.claim(
        queue: queue,
        leaseDuration: leaseDuration,
        types: handlers.keys.toList());
    if (lease == null) return JobRunOutcome.idle;
    try {
      await handlers[lease.job.type]!(lease);
    } catch (error) {
      // Bound stored diagnostics by UTF-8 bytes; application logging remains
      // the handler's responsibility. Never persist payloads/stack automatically.
      var message = error.toString();
      if (message.isEmpty) message = 'Handler failed';
      final bytes = utf8.encode(message);
      if (bytes.length > 4096) {
        message = utf8.decode(bytes.take(4096).toList(), allowMalformed: true);
      }
      while (utf8.encode(message).length > 4096) {
        message = message.substring(0, message.length - 1);
      }
      if (!await jobs.fail(lease, error: message)) {
        return JobRunOutcome.lostLease;
      }
      return lease.job.attempts < lease.job.maxAttempts
          ? JobRunOutcome.retried
          : JobRunOutcome.failed;
    }
    return await jobs.complete(lease)
        ? JobRunOutcome.completed
        : JobRunOutcome.lostLease;
  }
}
