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
        'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
    feed = await SqlitePlusChanges.open(database: db);
  });
  tearDown(() => db.close());
  Future<void> track({List<String>? columns}) =>
      feed.track(table: 'products', columns: columns);
  Future<void> insert(int id) => feed.transaction((tx) async {
        await tx
            .execute('INSERT INTO products VALUES(?,?,?)', [id, 'milk', 10]);
      });

  test('insert update delete stay ordered in one committed transaction',
      () async {
    await track();
    final c = await feed.consumer(name: 'search');
    await feed.transaction((tx) async {
      await tx.execute("INSERT INTO products VALUES(1,'milk',10)");
      await tx.execute('UPDATE products SET price=12 WHERE id=1');
      await tx.execute('DELETE FROM products WHERE id=1');
      await expectLater(c.read(), throwsStateError);
    });
    final batch = await c.read();
    expect(batch.transactions.length, 1);
    expect(batch.events.map((e) => e.kind),
        [ChangeKind.insert, ChangeKind.update, ChangeKind.delete]);
    expect(batch.events.elementAt(1).changedColumns, ['price']);
    expect(batch.events.first.key, {'id': BigInt.one});
    expect(batch.events.last.newKey, isNull);
    expect((await c.read()).events.length, 3);
    await c.acknowledge(batch.checkpoint);
    expect((await c.read()).events, isEmpty);
  });

  test(
      'rollback and no-op changes publish nothing; only selected columns matter',
      () async {
    await db.execute("INSERT INTO products VALUES(1,'milk',10)");
    await track(columns: ['name']);
    final c = await feed.consumer(name: 'c');
    await expectLater(feed.transaction((tx) async {
      await tx.execute("UPDATE products SET name='tea' WHERE id=1");
      throw StateError('abort');
    }), throwsStateError);
    await feed.transaction((tx) async {
      await tx.execute("UPDATE products SET name='milk',price=20 WHERE id=1");
    });
    expect((await feed.head()).batch, BigInt.zero);
    expect((await c.read()).events, isEmpty);
    await feed.transaction((tx) async {
      await tx.execute('UPDATE products SET id=2 WHERE id=1');
    });
    final event = (await c.read()).events.single;
    expect(event.changedColumns, ['id']);
    expect(event.oldKey, {'id': BigInt.one});
    expect(event.newKey, {'id': BigInt.two});
  });

  test('savepoint rollback discards its events and permits outer continuation',
      () async {
    await track();
    final c = await feed.consumer(name: 'c');
    late ChangeWriter retained;
    await feed.transaction((tx) async {
      retained = tx;
      await tx.execute("INSERT INTO products VALUES(1,'milk',10)");
      await expectLater(tx.savepoint((child) async {
        await child.execute("INSERT INTO products VALUES(2,'tea',20)");
        throw StateError('rollback child');
      }), throwsStateError);
      await tx.savepoint((child) async {
        await child.execute("INSERT INTO products VALUES(3,'rice',30)");
      });
    });
    expect((await c.read()).events.map((e) => e.key['id']),
        [BigInt.one, BigInt.from(3)]);
    await expectLater(
        retained.execute('DELETE FROM products'), throwsStateError);
  });

  test('scope guards, pragma requirement, DDL refusal and caller transactions',
      () async {
    await db.execute('PRAGMA recursive_triggers=OFF');
    await expectLater(track(), throwsStateError);
    await db.execute('PRAGMA recursive_triggers=ON');
    await track();
    await expectLater(db.execute("INSERT INTO products VALUES(1,'milk',1)"),
        throwsA(isA<SqlException>()));
    await expectLater(feed.transaction((tx) async {
      await tx.execute('COMMIT');
    }), throwsArgumentError);
    await expectLater(feed.transaction((tx) async {
      await tx.execute('DROP TABLE products');
    }), throwsArgumentError);
    await db.execute('BEGIN');
    await expectLater(feed.head(), throwsStateError);
    await db.execute('ROLLBACK');
    await db.execute('PRAGMA recursive_triggers=OFF');
    await expectLater(insert(1), throwsStateError);
    expect((await feed.head()).batch, BigInt.zero);
  });

  test('independent delivered/acknowledged positions survive reopening',
      () async {
    await track();
    final a = await feed.consumer(name: 'a'),
        b = await feed.consumer(name: 'b');
    await insert(1);
    await insert(2);
    final first = await a.read(maxTransactions: 1);
    expect(first.transactions.length, 1);
    await expectLater(a.acknowledge(await feed.head()), throwsArgumentError);
    await a.acknowledge(first.checkpoint);
    expect((await b.read()).events.length, 2);
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    final opened = await SqlitePlusChanges.open(database: copy);
    final again = await opened.consumer(name: 'a');
    expect((await again.read()).events.single.key['id'], BigInt.two);
    expect(ChangeCheckpoint.decode(first.checkpoint.encode()).batch,
        first.checkpoint.batch);
    final foreign = await openInMemory();
    addTearDown(foreign.close);
    final other = await SqlitePlusChanges.open(database: foreign);
    await expectLater(other.consumer(name: 'x', startAt: first.checkpoint),
        throwsArgumentError);
  });

  test(
      'safe pruning respects slow consumers; forced pruning expires explicitly',
      () async {
    await track();
    final a = await feed.consumer(name: 'a'),
        b = await feed.consumer(name: 'b');
    await insert(1);
    await insert(2);
    final all = await a.read();
    await a.acknowledge(all.checkpoint);
    expect((await feed.pruneAcknowledged()).batch, BigInt.zero);
    await expectLater(feed.pruneThrough(all.checkpoint), throwsStateError);
    await feed.pruneThrough(all.checkpoint, expireLaggingConsumers: true);
    await expectLater(b.read(), throwsA(isA<CheckpointExpired>()));
    await b.reset(await feed.head());
    expect((await b.read()).events, isEmpty);
    await expectLater(
        feed.consumer(name: 'new'), throwsA(isA<CheckpointExpired>()));
    await insert(3);
    expect((await b.read()).transactions.single.id, BigInt.from(3));
  });

  test('composite and signed64 keys keep types; key nulls are rejected',
      () async {
    await db.execute(
        'CREATE TABLE pairs(tenant TEXT NOT NULL,n INTEGER NOT NULL,value TEXT,PRIMARY KEY(tenant,n))');
    await feed.track(table: 'pairs');
    final c = await feed.consumer(name: 'c');
    final maximum = (BigInt.one << 63) - BigInt.one;
    await feed.transaction((tx) async {
      await tx
          .execute('INSERT INTO pairs VALUES(?,?,?)', ['001', maximum, 'x']);
    });
    expect((await c.read()).events.single.key, {'tenant': '001', 'n': maximum});
    await db.execute('CREATE TABLE nullable(k TEXT PRIMARY KEY,v TEXT)');
    await feed.track(table: 'nullable');
    await expectLater(feed.transaction((tx) async {
      await tx.execute("INSERT INTO nullable VALUES(NULL,'x')");
    }), throwsA(isA<SqlException>()));
  });

  test('REPLACE implicit deletes and foreign-key cascades are captured',
      () async {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute(
        'CREATE TABLE owners(id INTEGER PRIMARY KEY,code TEXT UNIQUE)');
    await db.execute(
        'CREATE TABLE children(id INTEGER PRIMARY KEY,owner INTEGER REFERENCES owners(id) ON DELETE CASCADE)');
    await feed.track(table: 'owners');
    await feed.track(table: 'children');
    final c = await feed.consumer(name: 'c');
    await feed.transaction((tx) async {
      await tx.execute("INSERT INTO owners VALUES(1,'same')");
      await tx.execute('INSERT INTO children VALUES(10,1)');
    });
    final initial = await c.read();
    await c.acknowledge(initial.checkpoint);
    await feed.transaction((tx) async {
      await tx.execute("INSERT OR REPLACE INTO owners VALUES(2,'same')");
    });
    final events = (await c.read()).events.toList();
    expect(
        events
            .where((e) => e.kind == ChangeKind.delete)
            .map((e) => e.table)
            .toSet(),
        {'owners', 'children'});
    expect(events.where((e) => e.kind == ChangeKind.insert).single.key['id'],
        BigInt.two);
  });

  test('schema and log corruption fail explicitly; untrack preserves history',
      () async {
    await track();
    final c = await feed.consumer(name: 'c');
    await insert(1);
    await db.execute('DROP TRIGGER _spc_1_update_event');
    await expectLater(c.read(), throwsStateError);
    await feed.untrack('products');
    expect((await c.read()).events.single.table, 'products');
    await db.execute('DELETE FROM _spc_events');
    await expectLater(c.read(), throwsA(isA<ChangeLogCorrupt>()));
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    await copy.execute('DROP TABLE _spc_batches');
    await expectLater(SqlitePlusChanges.open(database: copy),
        throwsA(isA<ChangeLogCorrupt>()));
  });

  test(
      'invalid definitions and unsupported FAIL trigger do not leave partial tracking',
      () async {
    await expectLater(feed.track(table: 'products', primaryKey: ['name']),
        throwsArgumentError);
    await expectLater(track(columns: ['missing']), throwsArgumentError);
    await db.execute(
        "CREATE TRIGGER failer AFTER UPDATE ON products BEGIN SELECT RAISE(FAIL,'bad'); END");
    await expectLater(track(), throwsStateError);
    expect((await db.query('SELECT * FROM _spc_sources')).rows, isEmpty);
    await db.execute('DROP TRIGGER failer');
    await track();
    await expectLater(track(), throwsStateError);
    await expectLater(feed.consumer(name: ''), throwsArgumentError);
    final c = await feed.consumer(name: 'valid');
    await expectLater(c.read(maxTransactions: 0), throwsArgumentError);
  });
}
