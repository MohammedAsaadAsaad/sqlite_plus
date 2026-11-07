import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final db = await openInMemory();
  await db.execute('PRAGMA recursive_triggers=ON');
  await db.execute(
      'CREATE TABLE items(tenant TEXT NOT NULL,n INTEGER NOT NULL,label TEXT,PRIMARY KEY(tenant,n))');
  final feed = await SqlitePlusChanges.open(database: db);
  await feed.track(table: 'items');
  final c = await feed.consumer(name: 'shared');
  final max = (BigInt.one << 63) - BigInt.one;
  await feed.transaction((tx) async {
    await tx.execute('INSERT INTO items VALUES(?,?,?)', ['001', max, 'حليب']);
    try {
      await tx.savepoint((child) async {
        await child.execute("UPDATE items SET label='rolled back'");
        throw StateError('savepoint');
      });
    } catch (_) {}
  });
  final batch = await c.read();
  check(batch.events.length == 1, 'Event count');
  check(batch.events.single.key['n'] == max, 'Signed64 key');
  check(batch.events.single.key['tenant'] == '001', 'Text key');
  check(ChangeCheckpoint.decode(batch.checkpoint.encode()).batch == BigInt.one,
      'Checkpoint encoding');
  await c.acknowledge(batch.checkpoint);
  await feed.pruneAcknowledged();
  final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
  final again = await SqlitePlusChanges.open(database: copy);
  final same = await again.consumer(name: 'shared');
  check((await same.read()).events.isEmpty, 'Reopen/retention');
  check(
      (await copy.query('SELECT label FROM items')).rows.single.single ==
          'حليب',
      'Savepoint value');
  await copy.close();
  await db.close();
  print('changes shared assertions passed');
}
