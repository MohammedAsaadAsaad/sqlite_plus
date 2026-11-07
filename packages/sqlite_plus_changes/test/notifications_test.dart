import 'dart:async';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';

void main() {
  test('post-commit hints exclude rollback/savepoint work and empty scopes',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 't');
    final signals = <ChangeNotification>[];
    final sub = feed.commits.listen((s) {
      expect(db.inTransaction, isFalse);
      signals.add(s);
    });
    addTearDown(sub.cancel);
    await feed.transaction((tx) async {});
    await expectLater(feed.transaction((tx) async {
      await tx.execute('INSERT INTO t VALUES(1,7)');
      throw StateError('rollback');
    }), throwsStateError);
    await feed.transaction((tx) async {
      await expectLater(tx.savepoint((child) async {
        await child.execute('INSERT INTO t VALUES(1,7)');
        throw StateError('savepoint');
      }), throwsStateError);
    });
    await Future<void>.delayed(Duration.zero);
    expect(signals, isEmpty);
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(2,8)'));
    await Future<void>.delayed(Duration.zero);
    expect(signals.length, 1);
    expect(signals.single.checkpoint.batch, BigInt.one);
    final before = db.exportImage();
    final batch = await feed.readSince(
        ChangeCheckpoint(signals.single.checkpoint.feedId, BigInt.zero));
    expect(batch.events.length, 1);
    expect(db.exportImage(), before);
    expect((await db.query('SELECT name FROM _spc_consumers')).rows, isEmpty);
    await feed.rotateGeneration();
    await Future<void>.delayed(Duration.zero);
    expect(signals.last.reset, isTrue);
  });

  test(
      'exclusive scopes serialize, enforce source guards and reject transaction leaks',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    final feeds = await Future.wait([
      SqlitePlusChanges.open(database: db),
      SqlitePlusChanges.open(database: db)
    ]);
    await feeds.first.track(table: 't');
    final events = <ChangeNotification>[];
    final sub = feeds.first.commits.listen(events.add);
    addTearDown(sub.cancel);
    await feeds.last.transaction((tx) => tx.execute('INSERT INTO t VALUES(1)'));
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 1);
    await expectLater(
        feeds.first.exclusive((db) => db.execute('INSERT INTO t VALUES(2)')),
        throwsA(isA<SqlException>()));
    await expectLater(
        feeds.first.exclusive((db) => db.execute('BEGIN')), throwsStateError);
    expect(db.inTransaction, isFalse);
    expect((await db.query('SELECT id FROM t')).rows, [
      [BigInt.one]
    ]);
  });

  test('stateless reads reject expiry/future/budgets and never hold pruning',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 't');
    final zero = await feed.head();
    await feed.transaction((tx) => tx.execute('INSERT INTO t VALUES(1),(2)'));
    await expectLater(feed.readSince(zero, maxEvents: 1),
        throwsA(isA<ChangeBatchTooLarge>()));
    await expectLater(feed.readSince(zero, maxEvents: 0), throwsArgumentError);
    await feed.pruneThrough(await feed.head());
    await expectLater(feed.readSince(zero), throwsA(isA<CheckpointExpired>()));
  });
}
