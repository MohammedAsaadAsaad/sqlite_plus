import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:test/test.dart';

void main() {
  test('composite BLOB/64-bit keys, quoted names, identical concurrent edits',
      () async {
    final db = await openInMemory();
    await db.execute(
        'CREATE TABLE "odd""table"("key""a" BLOB NOT NULL,"key b" INTEGER NOT NULL,value TEXT,PRIMARY KEY("key""a","key b")) WITHOUT ROWID');
    final key = BigInt.parse('9223372036854775807');
    await db.execute('INSERT INTO "odd""table" VALUES(?,?,?)', [
      Uint8List.fromList([0, 255]),
      key,
      'old'
    ]);
    final b = await SqlitePlusBranches(database: db, sourceId: 'odd')
        .create(name: 'test');
    try {
      await b.database.execute('UPDATE "odd""table" SET value=?', ['عربي']);
      await db.execute('UPDATE "odd""table" SET value=?', ['عربي']);
      expect((await b.previewMerge()).conflicts, isEmpty);
      expect((await b.merge()).appliedRows, 0);
      expect(
          (await db.query('SELECT "key b",value FROM "odd""table"'))
              .rows
              .single,
          [key, 'عربي']);
    } finally {
      await b.close();
      await db.close();
    }
  });

  test('main schema drift, metadata drift and virtual tables are rejected',
      () async {
    final db = await openInMemory();
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    final manager = SqlitePlusBranches(database: db, sourceId: 's');
    final b = await manager.create(name: 'draft');
    try {
      await b.database.execute('PRAGMA user_version=2');
      await expectLater(b.diff(), throwsA(isA<BranchException>()));
      await b.database.execute('PRAGMA user_version=0');
      await db.execute('CREATE INDEX extra ON t(n)');
      await expectLater(b.previewMerge(), throwsA(isA<BranchException>()));
      await expectLater(b.merge(), throwsA(isA<BranchException>()));
      await db.execute('CREATE VIRTUAL TABLE text USING fts5(body)');
      await expectLater(
          manager.create(name: 'unsupported'), throwsA(isA<BranchException>()));
    } finally {
      await b.close();
      await db.close();
    }
  });

  test('NULL keys and resource table/column limits fail explicitly', () async {
    final db = await openInMemory();
    try {
      await db.execute('CREATE TABLE t(id TEXT PRIMARY KEY,n INTEGER)');
      await db.execute('INSERT INTO t VALUES(NULL,1)');
      await expectLater(
          SqlitePlusBranches(database: db, sourceId: 's').create(name: 'null'),
          throwsA(isA<BranchException>()));
      await db.execute('DELETE FROM t');
      await expectLater(
          SqlitePlusBranches(
                  database: db,
                  sourceId: 's',
                  limits: const BranchLimits(maxColumns: 1))
              .create(name: 'wide'),
          throwsA(isA<BranchException>()));
      await db.execute('CREATE TABLE t2(id INTEGER PRIMARY KEY)');
      await expectLater(
          SqlitePlusBranches(
                  database: db,
                  sourceId: 's',
                  limits: const BranchLimits(maxTables: 1))
              .create(name: 'many'),
          throwsA(isA<BranchException>()));
    } finally {
      await db.close();
    }
  });

  test('two branches merge sequentially with receipts excluded from schema',
      () async {
    final db = await openInMemory();
    await db
        .execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a INTEGER,b INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,1,1)');
    final manager = SqlitePlusBranches(database: db, sourceId: 's');
    final a = await manager.create(name: 'a'),
        b = await manager.create(name: 'b');
    try {
      await a.database.execute('UPDATE t SET a=2');
      await b.database.execute('UPDATE t SET b=2');
      await a.merge();
      await b.merge();
      expect((await db.query('SELECT a,b FROM t')).rows.single,
          [BigInt.two, BigInt.two]);
      final c = await manager.create(name: 'after receipts');
      await c.database.execute('UPDATE t SET a=3');
      await c.merge();
      await c.close();
      expect(
          (await db.query('SELECT COUNT(*) FROM _spb_merges'))
              .rows
              .single
              .single,
          BigInt.from(3));
    } finally {
      await a.close();
      await b.close();
      await db.close();
    }
  });

  test('queued source managers and overlapping branch operations', () async {
    final db = await openInMemory();
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,1)');
    final manager = SqlitePlusBranches(database: db, sourceId: 's');
    final handles = await Future.wait([
      manager.create(name: 'one'),
      SqlitePlusBranches(database: db, sourceId: 's').create(name: 'two'),
    ]);
    try {
      expect(handles[0].id, isNot(handles[1].id));
      final diff = handles[0].diff();
      await expectLater(
          handles[0].exportArchive(), throwsA(isA<BranchException>()));
      expect(await diff, isEmpty);
      await handles[0].database.execute('DELETE FROM t');
      await db.execute('DELETE FROM t');
      expect((await handles[0].merge()).appliedRows, 0);
    } finally {
      for (final h in handles) {
        await h.close();
      }
      await db.close();
    }
  });

  test('portable checkpoints through simulated browser byte store', () async {
    final db = await openInMemory();
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,1)');
    final manager = SqlitePlusBranches(database: db, sourceId: 's');
    final branch = await manager.create(name: 'browser');
    final store = MemoryBrowserByteStore();
    await branch.database.execute('UPDATE t SET n=2');
    await store.write('draft', await branch.exportArchive());
    await branch.close();
    final restored = await manager.restore((await store.read('draft'))!);
    try {
      await restored.merge();
      expect(
          (await db.query('SELECT n FROM t')).rows.single.single, BigInt.two);
    } finally {
      await restored.close();
      await db.close();
    }
  });

  test('bad custom resolution CHECK fails atomically; invalid limits/names',
      () async {
    final db = await openInMemory();
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>=0))');
    await db.execute('INSERT INTO t VALUES(1,1)');
    final manager = SqlitePlusBranches(database: db, sourceId: 's'),
        b = await SqlitePlusBranches(database: db, sourceId: 's')
            .create(name: 'b');
    try {
      await db.execute('UPDATE t SET n=2');
      await b.database.execute('UPDATE t SET n=3');
      final c = (await b.previewMerge()).conflicts.single;
      final before = db.exportImage();
      await expectLater(
          b.merge(resolutions: {c.id: BranchResolution.value(-1)}),
          throwsA(anything));
      expect(db.exportImage(), before);
      await expectLater(
          manager.create(name: ''), throwsA(isA<ArgumentError>()));
      expect(() => SqlitePlusBranches(database: db, sourceId: ''),
          throwsArgumentError);
      expect(
          () => SqlitePlusBranches(
              database: db,
              sourceId: 's',
              limits: const BranchLimits(maxRows: 0)),
          throwsArgumentError);
      expect(() => BranchResolution.value(double.nan),
          throwsA(isA<BranchException>()));
    } finally {
      await b.close();
      await db.close();
    }
  });
}
