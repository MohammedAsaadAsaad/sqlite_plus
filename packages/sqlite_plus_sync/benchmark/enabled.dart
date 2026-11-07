import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import '../example/memory_server.dart';

Future<Map<String, Object>> sample(bool enabled) async {
  final db = await openInMemory();
  try {
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute(
        'INSERT INTO items VALUES ${List.filled(100, '(?,?)').join(',')}', [
      for (var i = 1; i <= 100; i++) ...[i, i]
    ]);
    final sourceBytes = db.exportImage().length;
    final feed = await SqlitePlusChanges.open(database: db);
    final activation = Stopwatch()..start();
    SqlitePlusSync? sync;
    final server = MemorySyncServer();
    if (enabled) {
      sync = await SqlitePlusSync.open(
          changes: feed, transport: server, scope: 'benchmark');
      await sync.register(table: 'items', columns: ['n'], seedExisting: true);
      await sync.runOnce();
    } else {
      await feed.track(table: 'items', columns: ['n']);
    }
    activation.stop();
    final readyBytes = db.exportImage().length;
    final write = Stopwatch()..start();
    await feed.transaction((tx) async {
      for (var i = 1; i <= 100; i++) {
        await tx.execute('UPDATE items SET n=? WHERE id=?', [100 + i, i]);
      }
    });
    write.stop();
    final logBytes = db.exportImage().length;
    final clock = Stopwatch()..start();
    final result = await sync?.runOnce();
    clock.stop();
    if (sync != null && result!.pushed != 100) {
      throw StateError('Missing outbox writes');
    }
    final sum = (await db.query('SELECT sum(n) FROM items')).rows.single.single;
    if (sum != BigInt.from(15050)) throw StateError('Wrong final data');
    return {
      'sync': enabled,
      'activation_bootstrap_us': activation.elapsedMicroseconds,
      'capture_100_us': write.elapsedMicroseconds,
      'run_once_us': clock.elapsedMicroseconds,
      'source_bytes': sourceBytes,
      'ready_bytes': readyBytes,
      'log_bytes': logBytes,
      'after_sync_bytes': db.exportImage().length,
      'rss': ProcessInfo.currentRss
    };
  } finally {
    await db.close();
  }
}

Future<void> main() async {
  final results = <Map<String, Object>>[];
  for (var i = 0; i < 3; i++) {
    for (final enabled in i.isEven ? [false, true] : [true, false]) {
      results.add(await sample(enabled));
    }
  }
  print(jsonEncode({
    'rows': 100,
    'updates': 100,
    'samples': results,
    'peak_rss': ProcessInfo.maxRss
  }));
}
