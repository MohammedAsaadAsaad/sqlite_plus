import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'memory_server.dart';

Future<void> main() async {
  final dbs = <MutableSqliteDatabase>[];
  final feeds = <SqlitePlusChanges>[];
  final syncs = <SqlitePlusSync>[];
  final server = MemorySyncServer();
  try {
    for (var i = 0; i < 2; i++) {
      final db = await openInMemory();
      dbs.add(db);
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute(
          'CREATE TABLE items(id INTEGER PRIMARY KEY,body BLOB,note TEXT)');
      final feed = await SqlitePlusChanges.open(database: db);
      feeds.add(feed);
      final sync = await SqlitePlusSync.open(
          changes: feed, transport: server, scope: 'shared');
      syncs.add(sync);
      await sync.register(table: 'items', columns: ['body', 'note']);
    }
    final key = BigInt.parse('9223372036854775807');
    await feeds.first
        .transaction((tx) => tx.execute('INSERT INTO items VALUES(?,?,?)', [
              key,
              Uint8List.fromList([0, 255]),
              'حليب'
            ]));
    await syncs.first.runOnce();
    await syncs.last.runOnce();
    final row = (await dbs.last.query('SELECT id,hex(body),note FROM items'))
        .rows
        .single;
    if (row[0] != key || row[1] != '00FF' || row[2] != 'حليب') {
      throw StateError('Typed synchronization failed');
    }
    await feeds.first.transaction((tx) =>
        tx.execute('UPDATE items SET note=? WHERE id=?', ['remote', key]));
    await syncs.first.runOnce();
    await feeds.last.transaction((tx) =>
        tx.execute('UPDATE items SET note=? WHERE id=?', ['local', key]));
    if ((await syncs.last.runOnce()).conflicts != 1) {
      throw StateError('Conflict was lost');
    }
    await syncs.last.resolveConflict(
        (await syncs.last.conflicts()).single.id, SyncResolution.keepLocal);
    await syncs.last.runOnce();
    await syncs.first.runOnce();
    final note =
        (await dbs.first.query('SELECT note FROM items')).rows.single.single;
    if (note != 'local') {
      throw StateError('Conflict resolution diverged');
    }
    final image = dbs.last.exportImage();
    final copy = await MutableSqliteDatabase.fromImage(image);
    try {
      await copy.execute('PRAGMA recursive_triggers=ON');
      final changes = await SqlitePlusChanges.open(database: copy);
      final sync = await SqlitePlusSync.open(
          changes: changes, transport: server, scope: 'shared');
      final count = server.applications;
      await sync.runOnce();
      if (server.applications != count) {
        throw StateError('Reopen caused an echo');
      }
    } finally {
      await copy.close();
    }
    print('sync shared assertions passed');
  } finally {
    for (final db in dbs) {
      await db.close();
    }
  }
}
