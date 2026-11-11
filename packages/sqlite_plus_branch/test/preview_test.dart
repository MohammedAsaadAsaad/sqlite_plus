import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusBranches branches;
  setUp(() async {
    db = await openInMemory();
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>=0))');
    await db.execute('INSERT INTO t VALUES(1,10)');
    branches = SqlitePlusBranches(database: db, sourceId: 's');
  });
  tearDown(() => db.close());

  test('callback runs once, explicit reviewed merge and idempotent close',
      () async {
    var calls = 0;
    final preview = await branches.preview((draft) async {
      calls++;
      await draft.execute('UPDATE t SET n=20');
      return 'done';
    });
    expect(preview.value, 'done');
    expect(preview.changes.single.changedColumns, ['n']);
    expect((await db.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(10));
    await preview.merge();
    await preview.merge();
    expect(calls, 1);
    expect((await db.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(20));
    await preview.close();
    await preview.close();
    await expectLater(preview.merge(), throwsA(isA<BranchException>()));
  });

  test('source edits after review invalidate approval', () async {
    final preview =
        await branches.preview((draft) => draft.execute('UPDATE t SET n=20'));
    await db.execute('UPDATE t SET n=30');
    await expectLater(preview.merge(), throwsA(isA<BranchException>()));
    await preview.close();
    expect((await db.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(30));
  });

  test('escaped working edits invalidate reviewed image', () async {
    late MutableSqliteDatabase escaped;
    final preview = await branches.preview((draft) async {
      escaped = draft;
      await draft.execute('UPDATE t SET n=20');
    });
    await escaped.execute('UPDATE t SET n=30');
    await expectLater(preview.merge(), throwsA(isA<BranchException>()));
    await preview.close();
  });

  test('callback failure closes draft and preserves original error', () async {
    late MutableSqliteDatabase escaped;
    final error = StateError('business failure');
    await expectLater(branches.preview((draft) async {
      escaped = draft;
      await draft.execute('UPDATE t SET n=20');
      throw error;
    }), throwsA(same(error)));
    expect(() => escaped.exportImage(), throwsStateError);
    expect((await db.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(10));
  });

  test(
      'open transaction or failed constraint cleans up without changing source',
      () async {
    final before = db.exportImage();
    await expectLater(branches.preview((draft) async {
      await draft.execute('BEGIN');
      await draft.execute('UPDATE t SET n=20');
    }), throwsA(isA<BranchException>()));
    await expectLater(
        branches.preview((draft) => draft.execute('UPDATE t SET n=-1')),
        throwsA(anything));
    expect(db.exportImage(), before);
  });

  test('ORM context uses a short-lived draft connection', () async {
    final id = Column<int, BigInt>(
        property: 'id',
        codec: Codecs.bigInt,
        keyOrder: 0,
        read: (x) => BigInt.one);
    final n =
        Column<int, int>(property: 'n', codec: Codecs.integer, read: (x) => x);
    final type = EntityType<int>(
        tableName: 't', columns: [id, n], create: (row) => row.read(n));
    final preview = await branches.preview((draft) async {
      final context =
          DbContext(MutableDatabaseConnection(draft), DbModel([type]));
      try {
        return await context.set(type).query.update({n: 21});
      } finally {
        await context.close();
      }
    });
    expect(preview.value.affectedRows, 1);
    await preview.merge();
    await preview.close();
    expect((await db.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(21));
  });
}
