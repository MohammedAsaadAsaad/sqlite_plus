import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart';
import 'package:test/test.dart';

void main() {
  test('raw watches recover from pruning/generation and leave no consumers',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 't');
    final reactive = ReactiveDatabase(feed);
    addTearDown(reactive.close);
    final values = <int>[];
    final q = reactive.watch('SELECT id,n FROM t ORDER BY id',
        dependencies: {'t': null}, keyColumns: ['id']);
    final sub = q.listen((s) => values.add(s.items.length));
    await reactive.flush();
    expect(values, [0]);
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(1,7)'));
    await feed.pruneThrough(await feed.head());
    await reactive.flush();
    expect(values.last, 1);
    await feed.rotateGeneration();
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(2,8)'));
    await reactive.flush();
    expect(values.last, 2);
    await sub.cancel();
    expect((await db.query('SELECT name FROM _spc_consumers')).rows, isEmpty);
  });

  test(
      'large or long log bursts trigger a full invalidation, not a skipped result',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 't');
    final source = ChangesReactiveSource(feed,
        maxEvents: 1, maxPages: 1, maxTransactions: 1);
    final registry = ReactiveRegistry(source: source);
    addTearDown(registry.close);
    final values = <int>[];
    final q = registry.watch<Map<String, Object?>>(
        sql: 'SELECT id FROM t',
        dependencies: {'t': null},
        keyColumns: ['id'],
        evaluate: () => feed.exclusive((db) => db.query('SELECT id FROM t')),
        decode: (r) => r);
    final sub = q.listen((s) => values.add(s.items.length));
    await registry.flush();
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(1),(2)'));
    await registry.flush();
    expect(values.last, 2);
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(3)'));
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(4)'));
    await registry.flush();
    expect(values.last, 4);
    await sub.cancel();
  });

  test(
      'untracked/incomplete dependencies fail explicitly and close is safe during startup',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    final feed = await SqlitePlusChanges.open(database: db);
    final reactive = ReactiveDatabase(feed);
    final errors = <Object>[];
    final sub = reactive.watch('SELECT * FROM t', dependencies: {
      't': null
    }, keyColumns: [
      'id'
    ]).listen((_) => fail('missing capture'), onError: errors.add);
    await reactive.flush();
    expect(errors, isNotEmpty);
    await sub.cancel();
    await reactive.close();
    final registry = ReactiveRegistry(source: ChangesReactiveSource(feed));
    final s = registry
        .watch<int>(
            sql: 'late',
            dependencies: {'t': null},
            evaluate: () async => QueryResult(['id'], []),
            decode: (r) => 0)
        .listen((_) {});
    await s.cancel();
    await registry.close();
  });
}
