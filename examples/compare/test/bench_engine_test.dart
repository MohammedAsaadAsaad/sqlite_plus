import 'dart:isolate';

import 'package:engine_bench/bench_model.dart';
import 'package:engine_bench/sqlite_plus_bench.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('count accepts 1 through 10000', () {
    expect(parseBenchCount('1'), 1);
    expect(parseBenchCount(' 10000 '), 10000);
    expect(parseBenchCount('0008'), 8);
    expect(parseBenchCount('0'), isNull);
    expect(parseBenchCount('10001'), isNull);
    expect(parseBenchCount('1.5'), isNull);
    expect(parseBenchCount(''), isNull);
    expect(parseBenchCount('الف'), isNull);
  });

  test('duration and size formatting hits the boundaries', () {
    expect(formatMicros(0), '0 µs');
    expect(formatMicros(999), '999 µs');
    expect(formatMicros(1000), '1.0 ms');
    expect(formatMicros(999999), '1000.0 ms');
    expect(formatMicros(1000000), '1.000 s');
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1024 * 1024), '1.00 MB');
    expect(formatClock(DateTime(2026, 10, 28, 7, 3, 4)), '07:03:04');
  });

  test('the copied log is oldest first and includes the comparison', () {
    BenchLogEntry entry(String id, int micros, DateTime at) => BenchLogEntry(
      at: at,
      sample: BenchSample(
        engineId: id,
        engineLabel: id,
        op: BenchOp.search,
        count: 5,
        elapsedMicros: micros,
        cpuMicros: 20,
        rssBefore: 1000,
        rssAfter: 1200,
        rows: 5,
        checksum: 10,
        hits: 5,
        prepareMicros: 30,
        exportMicros: id == 'sqlite_plus' ? 40 : 0,
        storedBytes: 4096,
      ),
    );
    final text = formatBenchLog([
      entry('sqlite_plus', 2000, DateTime(2026, 10, 28, 12, 50, 2)),
      entry('native', 4000, DateTime(2026, 10, 28, 12, 50, 1)),
    ]);
    expect(text.indexOf('12:50:01'), lessThan(text.indexOf('12:50:02')));
    expect(text, contains('native  Search  count=5  4.0 ms'));
    expect(text, contains('sqlite_plus  Search  count=5  2.0 ms'));
    expect(
      text,
      contains(
        'Search  sqlite_plus / native 0.50  match  rows 5/5  sum 10/10  hits 5/5',
      ),
    );
    expect(formatBenchLog(const []), isEmpty);
  });

  test('sample messages keep the measured fields', () {
    const sample = BenchSample(
      engineId: 'sqlite_plus',
      engineLabel: 'sqlite_plus',
      op: BenchOp.point,
      count: 4,
      elapsedMicros: 12,
      cpuMicros: 3,
      rssBefore: 10,
      rssAfter: 14,
      rows: 4,
      checksum: 10,
      hits: 4,
      prepareMicros: 5,
      exportMicros: 6,
      storedBytes: 4096,
    );
    final restored = BenchSample.fromMessage(sample.toMessage());
    expect(restored.op, BenchOp.point);
    expect(restored.checksum, 10);
    expect(restored.storedBytes, 4096);
    expect(restored.error, isNull);
  });

  test('sqlite_plus rejects a count outside 1 through 10000', () async {
    final engine = SqlitePlusBenchEngine();
    expect(
      () => engine.run(BenchOp.separateInsert, 0, (_, __) {}),
      throwsArgumentError,
    );
    expect(
      () => engine.run(BenchOp.separateInsert, 10001, (_, __) {}),
      throwsArgumentError,
    );
  });

  test('sqlite_plus operations agree on rows, hits, and checksum', () async {
    final engine = SqlitePlusBenchEngine();
    final separate = await engine.run(BenchOp.separateInsert, 4, (_, __) {});
    final batched = await engine.run(BenchOp.transactionInsert, 4, (_, __) {});
    expect(separate.rows, 4);
    expect(separate.hits, 4);
    expect(separate.checksum, benchInsertSum(4));
    expect(separate.elapsedMicros, greaterThan(0));
    expect(separate.storedBytes, greaterThan(0));
    expect(separate.exportMicros, greaterThanOrEqualTo(0));
    expect(batched.rows, separate.rows);
    expect(batched.checksum, separate.checksum);
    expect(batched.hits, separate.hits);

    final updated = await engine.run(BenchOp.separateUpdate, 4, (_, __) {});
    final bulk = await engine.run(BenchOp.bulkUpdate, 4, (_, __) {});
    expect(updated.rows, 4);
    expect(updated.hits, 4);
    expect(updated.checksum, benchInsertSum(4) + 4);
    expect(bulk.checksum, updated.checksum);
    expect(bulk.hits, 4);

    final search = await engine.run(BenchOp.search, 4, (_, __) {});
    final point = await engine.run(BenchOp.point, 4, (_, __) {});
    expect(search.hits, 4);
    expect(search.checksum, benchInsertSum(4));
    expect(point.hits, 4);
    expect(point.checksum, search.checksum);
    expect(search.prepareMicros, greaterThan(0));

    final vacuum = await engine.run(BenchOp.vacuum, 4, (_, __) {});
    expect(vacuum.hits, 1);
    expect(vacuum.rows, 4);
    expect(vacuum.checksum, benchInsertSum(4));

    final removed = await engine.run(BenchOp.separateDelete, 4, (_, __) {});
    final cleared = await engine.run(BenchOp.deleteAll, 4, (_, __) {});
    expect(removed.hits, 4);
    expect(removed.rows, 0);
    expect(removed.checksum, 0);
    expect(cleared.hits, 4);
    expect(cleared.rows, 0);
    expect(cleared.checksum, 0);
  });

  test('one separate insert is a single row', () async {
    final sample = await SqlitePlusBenchEngine().run(
      BenchOp.separateInsert,
      1,
      (_, __) {},
    );
    expect(sample.rows, 1);
    expect(sample.checksum, 1);
    expect(sample.hits, 1);
  });

  test('the isolate entry reports progress and the finished sample', () async {
    final receive = ReceivePort();
    await Isolate.spawn(sqlitePlusBenchEntry, {
      'send': receive.sendPort,
      'op': BenchOp.transactionInsert.index,
      'count': 3,
    });
    final messages = <Map<String, Object?>>[];
    await for (final message in receive.timeout(const Duration(seconds: 30))) {
      messages.add(Map<String, Object?>.from(message as Map));
      if (messages.last['kind'] == 'done') break;
    }
    receive.close();
    expect(messages.any((message) => message['kind'] == 'progress'), isTrue);
    final sample = BenchSample.fromMessage(messages.last);
    expect(sample.rows, 3);
    expect(sample.hits, 3);
    expect(sample.checksum, benchInsertSum(3));
    expect(sample.error, isNull);
  });
}
