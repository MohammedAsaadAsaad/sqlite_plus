import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';
import 'support/replica.dart';

void main() {
  test(
      'typed JSON round trips signed64, text, real, null, blobs and immutable snapshots',
      () {
    final blob = Uint8List.fromList([0, 255]);
    final record = SyncRecord(
        table: 't',
        key: {'id': BigInt.parse('9223372036854775807')},
        version: BigInt.one,
        values: {
          'id': BigInt.parse('9223372036854775807'),
          'text': 'حليب',
          'real': 1.25,
          'null': null,
          'blob': blob
        });
    blob[0] = 5;
    (record.values!['blob'] as Uint8List)[0] = 8;
    final copy = SyncRecord.fromJson(
        (jsonDecode(jsonEncode(record.toJson())) as Map)
            .cast<String, dynamic>());
    expect(copy.key['id'], BigInt.parse('9223372036854775807'));
    expect(copy.values!['blob'], [0, 255]);
    expect(copy.values!['real'], 1.25);
    expect(() => copy.key['id'] = 'bad', throwsUnsupportedError);
    expect(() => SyncCodec.value(BigInt.one << 63), throwsArgumentError);
    expect(() => SyncCodec.value(double.nan), throwsArgumentError);
    expect(
        () => SyncCodec.decodeValue(['integer', '01']), throwsFormatException);
    expect(() => SyncCodec.decodeValue(['unknown', 1]), throwsFormatException);
    expect(() => SyncCodec.value(true), throwsArgumentError);
  });

  test('composite integer/text keys, blobs and nullable fields synchronize',
      () async {
    final server = MemorySyncServer();
    final dbs = <MutableSqliteDatabase>[];
    final feeds = <SqlitePlusChanges>[];
    final syncs = <SqlitePlusSync>[];
    addTearDown(() async {
      for (final db in dbs) {
        await db.close();
      }
    });
    for (var i = 0; i < 2; i++) {
      final db = await openInMemory();
      dbs.add(db);
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute(
          'CREATE TABLE items(tenant TEXT,id INTEGER,body BLOB,note TEXT,PRIMARY KEY(tenant,id))');
      final changes = await SqlitePlusChanges.open(database: db);
      feeds.add(changes);
      final sync = await SqlitePlusSync.open(
          changes: changes, transport: server, scope: 'composite');
      syncs.add(sync);
      await sync.register(table: 'items', columns: ['body', 'note']);
    }
    await feeds.first
        .transaction((tx) => tx.execute('INSERT INTO items VALUES(?,?,?,?)', [
              'tenant',
              BigInt.parse('-9223372036854775808'),
              Uint8List.fromList([0, 255]),
              null
            ]));
    await syncs.first.runOnce();
    await syncs.last.runOnce();
    expect((await dbs.last.query('SELECT * FROM items')).rows, [
      [
        'tenant',
        BigInt.parse('-9223372036854775808'),
        Uint8List.fromList([0, 255]),
        null
      ]
    ]);
  });

  test('server replies cannot drop rows or advance an invalid cursor',
      () async {
    final server = MemorySyncServer();
    final hooks = Hooks(server);
    final c = await Replica.open(hooks);
    addTearDown(c.db.close);
    await c.write("INSERT INTO products VALUES('p','milk',10)");
    hooks.onPush = (op) async =>
        SyncPushResult(operationId: op.id, accepted: true, records: []);
    await expectLater(c.sync.runOnce(), throwsA(isA<SyncProtocolException>()));
    expect(
        (await c.db.query('SELECT id FROM _spsync_outbox WHERE id>0'))
            .rows
            .length,
        1);
    hooks.onPush = null;
    hooks.onPull = (request) async =>
        SyncPullPage(after: 'wrong', cursor: 'bad', records: []);
    await expectLater(c.sync.runOnce(), throwsA(isA<SyncProtocolException>()));
    expect(
        (await c.db.query('SELECT cursor FROM _spsync_state'))
            .rows
            .single
            .single,
        null);
    hooks.onPull = null;
    await c.sync.runOnce();
    expect(server.applications, 1);
  });

  for (final kind in [
    'unknown',
    'missing',
    'wrong-key',
    'zero-version',
    'stalled',
    'over-budget'
  ]) {
    test('malformed incoming $kind leaves source and cursor unchanged',
        () async {
      final server = MemorySyncServer();
      final hooks = Hooks(server);
      final c = await Replica.open(hooks);
      addTearDown(c.db.close);
      hooks.onPull = (request) async {
        final values = kind == 'missing'
            ? {'id': 'p', 'name': 'milk'}
            : {
                'id': kind == 'wrong-key' ? 'other' : 'p',
                'name': 'milk',
                'price': BigInt.from(10)
              };
        final record = SyncRecord(
            table: kind == 'unknown' ? 'other' : 'products',
            key: {'id': 'p'},
            version: kind == 'zero-version' ? BigInt.zero : BigInt.one,
            values: values);
        return SyncPullPage(
            after: request.after,
            cursor: kind == 'stalled' ? request.after : '1',
            records: kind == 'over-budget' ? [record, record] : [record]);
      };
      await expectLater(c.sync.runOnce(maxPullRecords: 1),
          throwsA(isA<SyncProtocolException>()));
      expect(await c.rows(), isEmpty);
      expect(
          (await c.db.query('SELECT cursor FROM _spsync_state'))
              .rows
              .single
              .single,
          null);
    });
  }

  test(
      'incoming constraint failure rolls back rows, revision, marker and cursor',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER CHECK(price>=0))');
    final feed = await SqlitePlusChanges.open(database: db);
    final hooks = Hooks(MemorySyncServer());
    final sync = await SqlitePlusSync.open(
        changes: feed, transport: hooks, scope: 'shop');
    await sync.register(table: 'products', columns: ['name', 'price']);
    hooks.onPull = (request) async =>
        SyncPullPage(after: request.after, cursor: '1', records: [
          SyncRecord(
              table: 'products',
              key: {'id': 'p'},
              version: BigInt.one,
              values: {'id': 'p', 'name': 'good', 'price': 10}),
          SyncRecord(
              table: 'products',
              key: {'id': 'q'},
              version: BigInt.two,
              values: {'id': 'q', 'name': 'bad', 'price': -1})
        ]);
    await expectLater(sync.runOnce(), throwsA(isA<SqlException>()));
    expect((await db.query('SELECT * FROM products')).rows, isEmpty);
    expect((await feed.head()).batch, BigInt.zero);
    expect((await db.query('SELECT * FROM _spsync_rows')).rows, isEmpty);
    expect(
        (await db.query('SELECT cursor FROM _spsync_state')).rows.single.single,
        null);
  });

  test('no-op incoming application cannot suppress the next local batch',
      () async {
    final server = MemorySyncServer();
    final a = await Replica.open(server);
    final b = await Replica.open(server);
    addTearDown(a.db.close);
    addTearDown(b.db.close);
    await a.write("INSERT INTO products VALUES('p','milk',10)");
    await a.sync.runOnce();
    await b.sync.runOnce();
    await b.sync.runOnce();
    await server.push(SyncOperation(id: 'external', scope: 'shop', mutations: [
      SyncMutation(
          table: 'products',
          key: {'id': 'p'},
          baseVersion: BigInt.one,
          values: {'id': 'p', 'name': 'milk', 'price': 10})
    ]));
    await b.sync.runOnce();
    expect((await b.db.query('SELECT id FROM _spsync_remote WHERE id>0')).rows,
        isEmpty);
    await b.write("UPDATE products SET price=15 WHERE id='p'");
    expect((await b.sync.runOnce()).pushed, 1);
    await a.sync.runOnce();
    expect((await a.rows()).single[2], BigInt.from(15));
  });

  test('partial group rejection supports absent keys and retry uses a fresh ID',
      () async {
    final server = MemorySyncServer();
    final a = await Replica.open(server);
    final b = await Replica.open(server);
    addTearDown(a.db.close);
    addTearDown(b.db.close);
    await a.write("INSERT INTO products VALUES('p','remote',10)");
    await a.sync.runOnce();
    await b.write("INSERT INTO products VALUES('p','local',20),('q','new',5)");
    expect((await b.sync.runOnce()).conflicts, 1);
    final old =
        (await b.db.query('SELECT operation_id FROM _spsync_outbox WHERE id>0'))
            .rows
            .single
            .single;
    await b.sync.resolveConflict(
        (await b.sync.conflicts()).single.id, SyncResolution.keepLocal);
    final next =
        (await b.db.query('SELECT operation_id FROM _spsync_outbox WHERE id>0'))
            .rows
            .single
            .single;
    expect(next, isNot(old));
    await b.sync.runOnce();
    await a.sync.runOnce();
    expect(await a.rows(), await b.rows());
  });

  test('untracking registered sources fails closed', () async {
    final server = MemorySyncServer();
    final c = await Replica.open(server);
    addTearDown(c.db.close);
    await c.changes.untrack('products');
    await expectLater(c.sync.runOnce(), throwsA(isA<SyncStateException>()));
  });

  test('same connection runs serialize and transport reentrancy is rejected',
      () async {
    final server = MemorySyncServer();
    final hooks = Hooks(server);
    final c = await Replica.open(hooks);
    addTearDown(c.db.close);
    var checked = false;
    hooks.onPull = (request) async {
      if (!checked) {
        checked = true;
        await expectLater(c.sync.runOnce(), throwsStateError);
      }
      return server.pull(request);
    };
    final results = await Future.wait([c.sync.runOnce(), c.sync.runOnce()]);
    expect(results.length, 2);
    expect(checked, isTrue);
  });
  for (final effect in ['transform', 'extra-key']) {
    test('incoming $effect trigger effects cannot silently diverge', () async {
      final db = await openInMemory();
      addTearDown(db.close);
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute(
          'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER)');
      await db.execute(effect == 'transform'
          ? "CREATE TRIGGER transform AFTER INSERT ON products BEGIN UPDATE products SET name='changed' WHERE id=NEW.id; END"
          : "CREATE TRIGGER extra AFTER INSERT ON products WHEN NEW.id='p' BEGIN INSERT INTO products VALUES('derived','other',5); END");
      final changes = await SqlitePlusChanges.open(database: db);
      final hooks = Hooks(MemorySyncServer());
      final sync = await SqlitePlusSync.open(
          changes: changes, transport: hooks, scope: 'shop');
      await sync.register(table: 'products', columns: ['name', 'price']);
      hooks.onPull =
          (r) async => SyncPullPage(after: r.after, cursor: '1', records: [
                SyncRecord(
                    table: 'products',
                    key: {'id': 'p'},
                    version: BigInt.one,
                    values: {'id': 'p', 'name': 'milk', 'price': 10})
              ]);
      await expectLater(sync.runOnce(), throwsA(isA<SyncStateException>()));
      expect((await db.query('SELECT * FROM products')).rows, isEmpty);
      expect((await changes.head()).batch, BigInt.zero);
    });
  }

  for (final kind in ['origin', 'discard']) {
    test('malformed $kind metadata fails closed before source data is lost',
        () async {
      final server = MemorySyncServer();
      final c = await Replica.open(server);
      addTearDown(c.db.close);
      await c.write("INSERT INTO products VALUES('p','milk',10)");
      await c.sync.runOnce();
      await c.write("UPDATE products SET price=20 WHERE id='p'");
      if (kind == 'origin') {
        await c.db.execute(
            'INSERT INTO _spsync_remote(feed,batch_id) VALUES(?,99999)',
            [(await c.changes.head()).feedId]);
      } else {
        await c.db.execute('UPDATE _spsync_rows SET discard_through=99999');
      }
      await expectLater(c.sync.runOnce(), throwsA(isA<SyncStateException>()));
      expect((await c.rows()).single[2], BigInt.from(20));
      expect(server.applications, 1);
    });
  }
}
