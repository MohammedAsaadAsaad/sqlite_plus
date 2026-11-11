import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlInspector inspector;
  setUp(() async {
    db = await openInMemory();
    inspector = SqlInspector();
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,tenant INTEGER,n INTEGER,label TEXT)');
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= 100; i++) "($i,${i % 5},$i,'item$i')"
    ].join(',')}');
  });
  tearDown(() async {
    inspector.close();
    await db.close();
  });
  test('candidate is measured on snapshot only and results agree', () async {
    final before = db.exportImage();
    final report = await inspector.adviseIndex(
        db, 'SELECT id,n FROM items WHERE tenant=? AND n>=? ORDER BY n',
        parameters: [2, 50]);
    final advice = report.advice!;
    expect(advice.columns, ['tenant', 'n']);
    expect(advice.beforeTimes.length, 3);
    expect(advice.afterTimes.length, 3);
    expect(advice.createSql, startsWith('CREATE INDEX'));
    expect(advice.addedBytes, greaterThan(0));
    expect(advice.writeCostMeasured, isFalse);
    expect(db.exportImage(), before);
    expect(inspector.snapshot().statementCount, 0);
  });
  test('existing prefix and PK access suppress redundant recommendations',
      () async {
    expect(
        (await inspector.adviseIndex(db, 'SELECT n FROM items WHERE id=?',
                parameters: [1]))
            .advice,
        isNull);
    await db.execute('CREATE INDEX present ON items(tenant,n)');
    final report = await inspector.adviseIndex(
        db, 'SELECT n FROM items WHERE tenant=? ORDER BY n',
        parameters: [1]);
    expect(report.advice, isNull);
    expect(report.reason, contains('prefix'));
  });
  for (final query in [
    'SELECT random() FROM items WHERE tenant=1',
    'SELECT * FROM items WHERE tenant=1 OR n=1',
    'SELECT * FROM items JOIN items b ON items.id=b.id',
    'SELECT * FROM items LIMIT 10',
    'WITH q AS (SELECT * FROM items) SELECT * FROM q',
    'DELETE FROM items',
    'SELECT * FROM items WHERE n=1; DELETE FROM items',
  ]) {
    test('unsupported SQL is not executed: $query', () async {
      final before = db.exportImage();
      expect((await inspector.adviseIndex(db, query)).advice, isNull);
      expect(db.exportImage(), before);
    });
  }
  test('budgets and caller transactions fail before sampling', () async {
    await expectLater(
        inspector.adviseIndex(db, 'SELECT n FROM items WHERE n>1',
            options: const IndexAdviceOptions(maxRows: 10)),
        throwsStateError);
    await expectLater(
        inspector.adviseIndex(db, 'SELECT n FROM items WHERE n>1',
            options: const IndexAdviceOptions(samples: 0)),
        throwsArgumentError);
    await db.execute('BEGIN');
    await expectLater(
        inspector.adviseIndex(db, 'SELECT n FROM items WHERE n>1'),
        throwsStateError);
    await db.execute('ROLLBACK');
  });
  test('nonbinary collation and descending order are explicit', () async {
    await db.execute(
        'CREATE TABLE words(id INTEGER PRIMARY KEY,word TEXT COLLATE NOCASE)');
    expect(
        (await inspector.adviseIndex(
                db, "SELECT word FROM words WHERE word='x'"))
            .advice,
        isNull);
    final report = await inspector.adviseIndex(
        db, 'SELECT n FROM items WHERE tenant=? ORDER BY n DESC',
        parameters: [1]);
    expect(report.advice!.createSql, contains('"n" DESC'));
  });
}
