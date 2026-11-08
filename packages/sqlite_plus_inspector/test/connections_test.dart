import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:test/test.dart';

void main() {
  test(
      'mutable adapter returns real rows, mutations and page without altering image',
      () async {
    final engine = await openInMemory();
    addTearDown(engine.close);
    final inspector = SqlInspector();
    final db = inspector.database(engine);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    final write =
        await db.execute('INSERT INTO t VALUES(1,7),(2,8) RETURNING id');
    expect(write.changes, 2);
    expect(write.returning!.rows.length, 2);
    final saved = engine.exportImage();
    final page = await db.page(table: 't', keyColumns: ['id'], size: 1);
    expect(page.items.single['n'], BigInt.from(7));
    expect(engine.exportImage(), saved);
    final report = inspector.snapshot();
    expect(report.executeCount, 2);
    expect(report.queryCount, 1);
    expect(report.records[1].rowCount, 2);
    expect(report.records[1].affectedRows, 2);
    await db.execute('BEGIN');
    expect(db.inTransaction, isTrue);
    await db.execute('ROLLBACK');
    expect(db.inTransaction, isFalse);
    await expectLater(
        db.query('SELECT bad FROM missing'), throwsA(isA<SqlException>()));
    expect(inspector.snapshot().failures, 1);
  });

  test('explicit plan inspection preserves rows, stats and scalar callbacks',
      () async {
    final engine = await openInMemory();
    addTearDown(engine.close);
    await engine.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await engine.execute('CREATE INDEX ix ON t(n)');
    await engine.execute('INSERT INTO t VALUES(1,7)');
    var evaluations = 0;
    engine.functions.registerScalar('tick', 0, (_) {
      evaluations++;
      return 1;
    });
    final inspector = SqlInspector();
    final db = inspector.database(engine);
    final before = engine.exportImage();
    final plan = await db.explain('SELECT tick() FROM t WHERE n=?', [7]);
    expect(plan.indexName, 'ix');
    expect(evaluations, 0);
    expect(engine.exportImage(), before);
    expect(inspector.snapshot().statementCount, 0);
    await expectLater(db.explain('DELETE FROM t'), throwsArgumentError);
    expect((await db.query('SELECT * FROM t')).rows.length, 1);
  });

  test('read-only wrapper, close, and disabled profiling preserve API results',
      () async {
    final engine = await openInMemory();
    await engine.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await engine.execute('INSERT INTO t VALUES(1)');
    final storage = MemoryStorageBackend();
    await storage.write(0, engine.exportImage());
    await engine.close();
    final readonly = await SqliteDatabase.openReadOnly(storage);
    final inspector = SqlInspector(enabled: false);
    final db = inspector.readOnly(readonly);
    expect((await db.query('SELECT * FROM t')).rows.single.single, BigInt.one);
    expect(inspector.snapshot().statementCount, 0);
    expect((await db.explain('SELECT id FROM t WHERE id=?', [1])).hasRowidBound,
        isTrue);
    await expectLater(db.execute('DELETE FROM t'), throwsUnsupportedError);
    await db.close();
    await expectLater(db.query('SELECT * FROM t'), throwsStateError);
  });
}
