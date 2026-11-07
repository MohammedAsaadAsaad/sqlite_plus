import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusChanges feed;
  setUp(() async {
    db = await openInMemory();
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,label TEXT COLLATE NOCASE)');
    feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'items');
  });
  tearDown(() => db.close());
  Future<void> insert(int id) => feed.transaction((tx) async {
        await tx.execute("INSERT INTO items VALUES(?,'a')", [id]);
      });
  test('event budgets never split a transaction or acknowledge omitted events',
      () async {
    final c = await feed.consumer(name: 'budget');
    await feed.transaction((tx) async {
      await tx.execute("INSERT INTO items VALUES(1,'a')");
      await tx.execute("UPDATE items SET label='A' WHERE id=1");
    });
    await insert(2);
    await expectLater(
        c.read(maxEvents: 1), throwsA(isA<ChangeBatchTooLarge>()));
    final first = await c.read(maxEvents: 2);
    expect(first.events.length, 2);
    expect(first.transactions.length, 1);
    expect(first.affectedKeys().single.key, {'id': BigInt.one});
    await c.acknowledge(first.checkpoint);
    expect((await c.read(maxEvents: 1)).events.single.key['id'], BigInt.two);
  });
  test('queued writes serialize and caught SQL failures cannot escape rollback',
      () async {
    final c = await feed.consumer(name: 'queue');
    await Future.wait([insert(1), insert(2)]);
    expect((await c.read()).transactions.map((t) => t.id),
        [BigInt.one, BigInt.two]);
    await expectLater(feed.transaction((tx) async {
      await tx.execute("INSERT INTO items VALUES(3,'a')");
      try {
        await tx.execute("INSERT INTO items VALUES(3,'duplicate')");
      } catch (_) {}
    }), throwsA(isA<SqlException>()));
    await feed.transaction((tx) async {
      await expectLater(tx.savepoint((child) async {
        await child.execute("INSERT INTO items VALUES(1,'duplicate')");
      }), throwsA(isA<SqlException>()));
      await tx.execute("INSERT INTO items VALUES(4,'a')");
    });
    await expectLater(feed.transaction((tx) async {
      try {
        await tx.execute("INSERT OR ROLLBACK INTO items VALUES(1,'duplicate')");
      } catch (_) {}
      await tx.execute("INSERT INTO items VALUES(5,'escape')");
    }), throwsStateError);
    expect((await db.query('SELECT id FROM items WHERE id IN (3,5)')).rows,
        isEmpty);
  });
  test('expired consumers reopen for reset and indexes are validated',
      () async {
    final c = await feed.consumer(name: 'slow');
    await insert(1);
    final batch = await c.read();
    await feed.pruneThrough(batch.checkpoint, expireLaggingConsumers: true);
    await expectLater(
        c.acknowledge(batch.checkpoint), throwsA(isA<CheckpointExpired>()));
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    final opened = await SqlitePlusChanges.open(database: copy);
    final expired = await opened.consumer(name: 'slow');
    await expectLater(expired.read(), throwsA(isA<CheckpointExpired>()));
    await expired.reset(await opened.head());
    expect((await expired.read()).events, isEmpty);
    await copy.execute('DROP INDEX _spc_batches_count');
    await expectLater(opened.head(), throwsA(isA<ChangeLogCorrupt>()));
  });
  test('out-of-band schema repair requires explicit opt-in and untrack',
      () async {
    await insert(1);
    await db.execute('DROP TRIGGER _spc_1_update_event');
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    await expectLater(SqlitePlusChanges.open(database: copy), throwsStateError);
    final repair =
        await SqlitePlusChanges.open(database: copy, allowSchemaRepair: true);
    await repair.untrack('items');
    expect((await repair.head()).batch, BigInt.one);
  });
  test(
      'generation rotation invalidates old checkpoints and requires consumer reset',
      () async {
    final c = await feed.consumer(name: 'generation');
    await insert(1);
    final batch = await c.read();
    final oldId = batch.checkpoint.feedId;
    await feed.rotateGeneration();
    expect((await feed.head()).feedId, isNot(oldId));
    await expectLater(c.read(), throwsA(isA<CheckpointExpired>()));
    await expectLater(c.acknowledge(batch.checkpoint), throwsArgumentError);
    await expectLater(feed.consumer(name: 'new', startAt: batch.checkpoint),
        throwsArgumentError);
    await c.reset(await feed.head());
    await insert(2);
    expect((await c.read()).events.single.key['id'], BigInt.two);
  });
  test('producer budget rolls back oversized transactions before publication',
      () async {
    final c = await feed.consumer(name: 'producer-budget');
    await expectLater(
        feed.transaction((tx) async {
          await tx.execute("INSERT INTO items VALUES(1,'a'),(2,'b')");
        }, maxEvents: 1),
        throwsA(isA<ChangeBatchTooLarge>()));
    expect((await db.query('SELECT * FROM items')).rows, isEmpty);
    expect((await c.read()).events, isEmpty);
  });
  test('concurrent opens share reentrancy protection for the connection',
      () async {
    final other = await openInMemory();
    addTearDown(other.close);
    await other.execute('PRAGMA recursive_triggers=ON');
    final handles = await Future.wait([
      SqlitePlusChanges.open(database: other),
      SqlitePlusChanges.open(database: other),
    ]);
    await handles.first.transaction((tx) async {
      await expectLater(handles.last.head(), throwsStateError);
    });
  });
}
