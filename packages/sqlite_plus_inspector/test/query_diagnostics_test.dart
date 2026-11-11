import 'dart:convert';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';
import 'package:test/test.dart';
import '../example/model.dart';

void main() {
  test(
      'explicit mutable profile snapshots source and records whole wrapper time',
      () async {
    final db = await openInMemory();
    final inspector = SqlInspector();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
      await db.execute('INSERT INTO t VALUES ${[
        for (var i = 1; i <= 100; i++) '($i,${i % 17})'
      ].join(',')}');
      final before = db.exportImage();
      final connection = inspector.database(db);
      final report = await connection.profile(
          'SELECT id FROM t WHERE n>=? ORDER BY n,id LIMIT 32',
          parameters: [5]);
      expect(report.result.rows.length, 32);
      expect(report.rowsLoaded, 100);
      expect(report.sortStrategy, 'bounded-heap');
      expect(db.exportImage(), before);
      final records = inspector.snapshot().records;
      expect(records.length, 1);
      expect(records.single.rowCount, 32);
      expect(records.single.duration, greaterThanOrEqualTo(report.totalTime));
      expect(records.single.parameters, ['<integer>']);
      expect(jsonEncode(report.toJson()).contains('SELECT'), false);
      inspector.enabled = false;
      expect(
          (await connection.profile('SELECT id FROM t LIMIT 1'))
              .result
              .rows
              .length,
          1);
      expect(inspector.snapshot().records.length, 1);
    } finally {
      await db.close();
      inspector.close();
    }
  });
  test(
      'read-only profile and unsupported custom capability preserve adapter calls',
      () async {
    final db = await openInMemory();
    final inspector = SqlInspector();
    final reader =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    try {
      final report = await inspector
          .readOnly(reader)
          .profile('SELECT ?', parameters: ['private-marker']);
      expect(report.result.rows, [
        ['private-marker']
      ]);
      expect(jsonEncode(report.toJson()).contains('private-marker'), false);
      var calls = 0;
      final custom = InspectedConnection(
          inspector: inspector,
          query: (sql, args) {
            calls++;
            return db.query(sql, args);
          });
      await expectLater(custom.profile('SELECT 1'), throwsUnsupportedError);
      expect(calls, 0);
      await custom.query('SELECT 1');
      expect(calls, 1);
    } finally {
      await reader.close();
      await db.close();
      inspector.close();
    }
  });
  test('ORM profile respects adapter close and another context lease',
      () async {
    final db = await openInMemory();
    final inspector = SqlInspector();
    final closed = inspector.ormConnection(MutableDatabaseConnection(db));
    await closed.close();
    await expectLater(
        closed.profile('SELECT 1'), throwsA(isA<OrmStateException>()));
    final owner = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    final borrowed = inspector.ormConnection(MutableDatabaseConnection(db));
    await expectLater(
        borrowed.profile('SELECT 1'), throwsA(isA<OrmStateException>()));
    await owner.close();
    expect((await borrowed.profile('SELECT 1')).result.rows, [
      [BigInt.one]
    ]);
    await borrowed.close();
    inspector.close();
    await db.close();
  });
  for (final capture in [false, true]) {
    test(
        'explicit ORM profile remains scoped and preserves capture/tracking capture=$capture',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = capture ? await SqlitePlusChanges.open(database: db) : null;
      final inspector = SqlInspector();
      final connection =
          inspector.ormConnection(MutableDatabaseConnection(db), changes: feed);
      final context = DbContext(connection, DbModel([type]));
      try {
        await context.migrations.ensureCreated();
        final products = context.set(type);
        products.add(Product(BigInt.one, 'a', 10));
        await context.saveChanges();
        final tracked = await products.query.single();
        final before = db.exportImage();
        final report = await connection.profile(
            'SELECT price FROM products WHERE id=?',
            parameters: [BigInt.one]);
        expect(report.result.rows, [
          [BigInt.from(10)]
        ]);
        expect(identical(tracked, await products.query.single()), true);
        expect(db.exportImage(), before);
        tracked.price = 20;
        await context.saveChanges();
        expect((await products.query.asNoTracking().single()).price, 20);
        if (feed != null) {
          expect(feed, isNotNull);
        }
      } finally {
        await context.close();
        await db.close();
        inspector.close();
      }
    });
  }
}
