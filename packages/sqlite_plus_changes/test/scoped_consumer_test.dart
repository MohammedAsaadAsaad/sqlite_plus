import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';

void main() {
  test('application output and scoped delivery/ack roll back together',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('CREATE TABLE output(id INTEGER PRIMARY KEY)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'docs');
    final consumer = await feed.consumer(name: 'worker');
    await feed.transaction((tx) => tx.execute('INSERT INTO docs VALUES(1,7)'));
    final before = db.exportImage();
    await expectLater(feed.transaction((tx) async {
      expect(await tx.pendingCheckpoint(), null);
      final batch = await tx.readChanges(consumer);
      expect(batch.events.length, 1);
      await tx.execute('INSERT INTO output VALUES(1)');
      await tx.acknowledge(consumer, batch.checkpoint);
      throw StateError('after acknowledgement');
    }), throwsStateError);
    expect(db.exportImage(), before);
    expect((await consumer.read()).events.length, 1);
    await feed.transaction((tx) async {
      final batch = await tx.readChanges(consumer);
      await tx.execute('INSERT INTO output VALUES(1)');
      await tx.acknowledge(consumer, batch.checkpoint);
    });
    expect((await consumer.read()).events, isEmpty);
    expect((await db.query('SELECT id FROM output')).rows, [
      [BigInt.one]
    ]);
  });

  test('pending checkpoint reflects captured events and savepoint rollback',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,n INTEGER)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'docs');
    final sources = await feed.sources();
    expect(sources.single.primaryKey, ['id']);
    expect(() => sources.single.columns.add('other'), throwsUnsupportedError);
    await feed.transaction((tx) async {
      expect(tx.baseCheckpoint.batch, BigInt.zero);
      await expectLater(tx.savepoint((child) async {
        await child.execute('INSERT INTO docs VALUES(1,7)');
        expect((await child.pendingCheckpoint())!.batch, BigInt.one);
        expect((await child.pendingChanges()).events.length, 1);
        throw StateError('rollback');
      }), throwsStateError);
      expect(await tx.pendingCheckpoint(), null);
      expect((await tx.pendingChanges()).events, isEmpty);
      await tx.execute('INSERT INTO docs VALUES(2,8)');
      expect((await tx.pendingCheckpoint())!.batch, BigInt.one);
    });
    expect((await feed.head()).batch, BigInt.one);
  });

  test(
      'resumeExisting never skips work and cross-database scoped consumers fail',
      () async {
    final db = await openInMemory();
    final other = await openInMemory();
    addTearDown(db.close);
    addTearDown(other.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'docs');
    await feed.consumer(name: 'worker');
    await feed.transaction((tx) => tx.execute('INSERT INTO docs VALUES(1)'));
    final resumed = await feed.consumer(
        name: 'worker', startAt: await feed.head(), resumeExisting: true);
    expect((await resumed.read()).events.length, 1);
    final foreign = await (await SqlitePlusChanges.open(database: other))
        .consumer(name: 'worker');
    await expectLater(
        feed.transaction((tx) => tx.readChanges(foreign)), throwsArgumentError);
  });
}
