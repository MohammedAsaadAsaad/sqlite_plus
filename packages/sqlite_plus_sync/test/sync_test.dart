import 'dart:convert';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';
import 'support/replica.dart';

void main() {
  late MemorySyncServer server;
  late Replica a, b;
  setUp(() async {
    server = MemorySyncServer();
    a = await Replica.open(server, id: 'a');
    b = await Replica.open(server, id: 'b');
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });
  Future<void> seed() async {
    await a.write("INSERT INTO products VALUES('p','milk',10)");
    await a.sync.runOnce();
    await b.sync.runOnce();
  }

  test(
      'offline grouped changes converge and remote writes stay visible without echo',
      () async {
    await a.write("INSERT INTO products VALUES('p','milk',10),('q','tea',20)");
    expect(server.applications, 0);
    expect((await a.sync.runOnce()).pushed, 2);
    expect((await b.sync.runOnce()).pulled, 2);
    expect(await b.rows(), await a.rows());
    final cache = await b.changes.consumer(name: 'cache');
    final events = await cache.read();
    expect(events.transactions.length, 1);
    expect(events.events.length, 2);
    await b.sync.runOnce();
    expect(server.applications, 1);
    expect((await cache.read()).events.length, 2);
  });

  test(
      'lost response retries the identical frozen operation after image reopen',
      () async {
    final hooks = Hooks(server);
    final client = await Replica.open(hooks, id: 'retry');
    await client.write("INSERT INTO products VALUES('p','milk',10)");
    String? frozen;
    hooks.onPush = (op) async {
      frozen = jsonEncode(op.toJson());
      await server.push(op);
      throw StateError('lost reply');
    };
    await expectLater(client.sync.runOnce(), throwsStateError);
    final image = client.db.exportImage();
    await client.db.close();
    final reopened = await Replica.open(hooks, image: image);
    addTearDown(reopened.db.close);
    hooks.onPush = (op) async {
      expect(jsonEncode(op.toJson()), frozen);
      return server.push(op);
    };
    expect((await reopened.sync.runOnce()).pushed, 1);
    expect(server.applications, 1);
    expect(
        (await reopened.db.query('SELECT id FROM _spsync_outbox WHERE id>0'))
            .rows,
        isEmpty);
  });

  test('local edit during push remains local and is sent on the next run',
      () async {
    final hooks = Hooks(server);
    final c = await Replica.open(hooks);
    addTearDown(c.db.close);
    await c.write("INSERT INTO products VALUES('p','milk',10)");
    hooks.onPush = (op) async {
      final result = await server.push(op);
      await c.write("UPDATE products SET price=99 WHERE id='p'");
      return result;
    };
    await c.sync.runOnce();
    expect((await c.rows()).single[2], BigInt.from(99));
    hooks.onPush = null;
    await c.sync.runOnce();
    await b.sync.runOnce();
    expect((await b.rows()).single[2], BigInt.from(99));
    expect(server.applications, 2);
  });

  for (final resolution in SyncResolution.values) {
    test('push conflict persists, blocks networking, and resolves $resolution',
        () async {
      await seed();
      await a.write("UPDATE products SET price=12 WHERE id='p'");
      await a.sync.runOnce();
      await b.write("UPDATE products SET price=99 WHERE id='p'");
      expect((await b.sync.runOnce()).conflicts, 1);
      final calls = server.pushCalls + server.pullCalls;
      expect((await b.sync.runOnce()).conflicts, 1);
      expect(server.pushCalls + server.pullCalls, calls);
      final conflicts = await b.sync.conflicts();
      expect(conflicts.single.direction, 'push');
      await b.sync.resolveConflict(conflicts.single.id, resolution);
      expect(await b.sync.conflicts(), isEmpty);
      await b.sync.runOnce();
      await a.sync.runOnce();
      final expected = resolution == SyncResolution.keepLocal ? 99 : 12;
      expect((await a.rows()).single[2], BigInt.from(expected));
      expect((await b.rows()).single[2], BigInt.from(expected));
    });

    test('local edit during pull is preserved until explicit $resolution',
        () async {
      await seed();
      await a.write("UPDATE products SET price=12 WHERE id='p'");
      await a.sync.runOnce();
      final hooks = Hooks(server);
      final c = await Replica.open(hooks, image: b.db.exportImage());
      addTearDown(c.db.close);
      hooks.onPull = (request) async {
        final page = await server.pull(request);
        await c.write("UPDATE products SET price=99 WHERE id='p'");
        return page;
      };
      expect((await c.sync.runOnce()).conflicts, 1);
      expect((await c.rows()).single[2], BigInt.from(99));
      final conflict = (await c.sync.conflicts()).single;
      expect(conflict.direction, 'pull');
      hooks.onPull = null;
      await c.sync.resolveConflict(conflict.id, resolution);
      await c.sync.runOnce();
      await a.sync.runOnce();
      final expected = resolution == SyncResolution.keepLocal ? 99 : 12;
      expect((await a.rows()).single[2], BigInt.from(expected));
      expect((await c.rows()).single[2], BigInt.from(expected));
      if (resolution == SyncResolution.acceptRemote) {
        expect(server.applications, 2);
      }
    });
  }

  test('acceptRemote also discards newer edits only for the conflicted key',
      () async {
    await seed();
    await a.write("UPDATE products SET price=12 WHERE id='p'");
    await a.sync.runOnce();
    await b.write("UPDATE products SET price=99 WHERE id='p'");
    await b.sync.runOnce();
    await b.write("UPDATE products SET name='later' WHERE id='p'");
    await b.write("INSERT INTO products VALUES('q','keep',5)");
    await b.sync.resolveConflict(
        (await b.sync.conflicts()).single.id, SyncResolution.acceptRemote);
    await b.sync.runOnce();
    await a.sync.runOnce();
    expect(await a.rows(), [
      ['p', 'milk', BigInt.from(12)],
      ['q', 'keep', BigInt.from(5)]
    ]);
  });

  test('delete tombstones and resurrection synchronize without echo', () async {
    await seed();
    await a.write("DELETE FROM products WHERE id='p'");
    await a.sync.runOnce();
    await b.sync.runOnce();
    expect(await b.rows(), isEmpty);
    await b.sync.runOnce();
    expect(server.applications, 2);
    await b.write("INSERT INTO products VALUES('p','again',5)");
    await b.sync.runOnce();
    await a.sync.runOnce();
    expect(await a.rows(), await b.rows());
    expect(server.applications, 3);
  });

  test('key changes are an atomic old-key deletion and new-key insertion',
      () async {
    await seed();
    await a.write("UPDATE products SET id='new' WHERE id='p'");
    expect((await a.sync.runOnce()).pushed, 2);
    await b.sync.runOnce();
    expect(await b.rows(), await a.rows());
  });

  test(
      'whole-batch budget failures leave outbox and consumer progress unchanged',
      () async {
    await a.write("INSERT INTO products VALUES('p','milk',10),('q','tea',20)");
    await expectLater(
        a.sync.runOnce(maxMutations: 1), throwsA(isA<SyncStateException>()));
    expect((await a.db.query('SELECT id FROM _spsync_outbox WHERE id>0')).rows,
        isEmpty);
    await expectLater(
        a.sync.runOnce(maxEvents: 1), throwsA(isA<ChangeBatchTooLarge>()));
    expect((await a.sync.runOnce(maxMutations: 2)).pushed, 2);
  });

  test('forced retention and generation changes fail closed', () async {
    await a.write("INSERT INTO products VALUES('p','milk',10)");
    await a.changes
        .pruneThrough(await a.changes.head(), expireLaggingConsumers: true);
    await expectLater(a.sync.runOnce(), throwsA(isA<CheckpointExpired>()));
    expect(server.pushCalls, 0);
    await b.changes.rotateGeneration();
    await expectLater(b.sync.runOnce(), throwsA(isA<SyncStateException>()));
  });

  test('namespace, replica, schema and registration drift are rejected',
      () async {
    await expectLater(
        SqlitePlusSync.open(
            changes: a.changes, transport: server, scope: 'other'),
        throwsA(isA<SyncStateException>()));
    await expectLater(
        SqlitePlusSync.open(
            changes: a.changes,
            transport: server,
            scope: 'shop',
            replicaId: 'other'),
        throwsA(isA<SyncStateException>()));
    await a.sync.register(table: 'products', columns: ['name', 'price']);
    await expectLater(a.sync.register(table: 'products', columns: ['name']),
        throwsA(isA<SyncStateException>()));
    await a.db.execute('DROP INDEX _spsync_remote_batch');
    await expectLater(a.sync.runOnce(), throwsA(isA<SyncStateException>()));
  });

  test('bootstrap is explicit, bounded and recoverable with typed rows',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER)');
    await db
        .execute("INSERT INTO products VALUES('p','seed',8),('q','second',9)");
    final changes = await SqlitePlusChanges.open(database: db);
    final sync = await SqlitePlusSync.open(
        changes: changes, transport: server, scope: 'shop');
    await expectLater(
        sync.register(table: 'products', columns: ['name', 'price']),
        throwsA(isA<SyncStateException>()));
    await expectLater(
        sync.register(
            table: 'products',
            columns: ['name', 'price'],
            seedExisting: true,
            maxSeedRows: 1),
        throwsA(isA<SyncStateException>()));
    await sync.register(
        table: 'products', columns: ['name', 'price'], seedExisting: true);
    expect((await sync.runOnce()).pushed, 2);
    await b.sync.runOnce();
    expect((await b.rows()).length, 2);
  });

  test(
      'untracked disabled database stays ordinary and scoped server data is isolated',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE ordinary(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO ordinary VALUES(1)');
    expect(
        (await db.query(
                "SELECT name FROM sqlite_schema WHERE name LIKE '_spsync_%'"))
            .rows,
        isEmpty);
    await seed();
    final c = await Replica.open(server, scope: 'other');
    addTearDown(c.db.close);
    expect((await c.sync.runOnce()).pulled, 0);
    expect(await c.rows(), isEmpty);
  });
}
