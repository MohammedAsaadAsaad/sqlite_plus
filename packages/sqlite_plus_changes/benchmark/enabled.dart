import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';

Future<Map<String, Object>> sample(bool enabled, int rows, int updates) async {
  final db = await openInMemory();
  try {
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,body TEXT,n INTEGER)');
    for (var start = 0; start < rows; start += 500) {
      await db.execute(
          'INSERT INTO items VALUES ${List.filled(rows - start < 500 ? rows - start : 500, '(?,?,?)').join(',')}',
          [
            for (var i = start; i < rows && i < start + 500; i++) ...[
              i + 1,
              'product name with extra text number $i',
              i
            ]
          ]);
    }
    final sourceBytes = db.exportImage().length;
    final activation = Stopwatch()..start();
    final feed = enabled ? await SqlitePlusChanges.open(database: db) : null;
    if (feed != null) await feed.track(table: 'items', columns: ['n']);
    final consumer =
        feed == null ? null : await feed.consumer(name: 'benchmark');
    activation.stop();
    final readyBytes = db.exportImage().length;
    final clock = Stopwatch()..start();
    if (feed == null) {
      await db.execute('BEGIN');
      for (var i = 1; i <= updates; i++) {
        await db.execute('UPDATE items SET n=? WHERE id=?', [rows + i, i]);
      }
      await db.execute('COMMIT');
    } else {
      await feed.transaction((tx) async {
        for (var i = 1; i <= updates; i++) {
          await tx.execute('UPDATE items SET n=? WHERE id=?', [rows + i, i]);
        }
      });
    }
    clock.stop();
    final loggedBytes = db.exportImage().length;
    final read = Stopwatch()..start();
    final batch = consumer == null ? null : await consumer.read();
    read.stop();
    if (batch != null && batch.events.length != updates) {
      throw StateError('Missing changes');
    }
    if (batch != null) {
      var id = 1;
      for (final event in batch.events) {
        if (event.kind != ChangeKind.update ||
            event.oldKey?['id'] != BigInt.from(id) ||
            event.newKey?['id'] != BigInt.from(id) ||
            event.changedColumns.length != 1 ||
            event.changedColumns.single != 'n') {
          throw StateError('Incorrect event at $id');
        }
        id++;
      }
    }
    if (consumer != null) {
      await consumer.acknowledge(batch!.checkpoint);
      await feed!.pruneAcknowledged();
    }
    return {
      'enabled': enabled,
      'activation_us': activation.elapsedMicroseconds,
      'update_us': clock.elapsedMicroseconds,
      if (updates == 100) 'update_100_us': clock.elapsedMicroseconds,
      'read_us': read.elapsedMicroseconds,
      'source_bytes': sourceBytes,
      'ready_bytes': readyBytes,
      'logged_bytes': loggedBytes,
      'after_prune_bytes': db.exportImage().length,
      'rss': ProcessInfo.currentRss
    };
  } finally {
    await db.close();
  }
}

Future<void> main(List<String> args) async {
  final rows = args.isEmpty ? 1000 : int.parse(args[0]);
  final samples = args.length < 2 ? 5 : int.parse(args[1]);
  final updates = args.length < 3 ? 100 : int.parse(args[2]);
  if (rows < 1 || samples < 1 || updates < 1 || updates > rows) {
    throw ArgumentError(
        'rows/samples/updates must be positive; updates <= rows');
  }
  final result = <Map<String, Object>>[];
  for (var i = 0; i < samples; i++) {
    for (final enabled in i.isEven ? [false, true] : [true, false]) {
      result.add(await sample(enabled, rows, updates));
    }
  }
  print(jsonEncode({
    'rows': rows,
    'updates': updates,
    'samples': result,
    'peak_rss': ProcessInfo.maxRss
  }));
}
