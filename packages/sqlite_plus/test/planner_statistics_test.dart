import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class _CountingStorage implements StorageBackend {
  _CountingStorage(this.inner);
  final StorageBackend inner;
  var reads = 0;
  @override
  Future<int> read(int offset, Uint8List target) {
    reads++;
    return inner.read(offset, target);
  }

  @override
  Future<void> write(int offset, Uint8List bytes) => inner.write(offset, bytes);
  @override
  Future<void> truncate(int length) => inner.truncate(length);
  @override
  Future<int> length() => inner.length();
  @override
  Future<void> sync() => inner.sync();
  @override
  Future<void> close() => inner.close();
}

void main() {
  Future<MutableSqliteDatabase> database({int encoding = 1}) async {
    final db =
        await MutableSqliteDatabase.create(pageSize: 512, encoding: encoding);
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,a INT,b INT,c INT,payload TEXT)');
    await db.execute('INSERT INTO items WITH RECURSIVE n(x) AS('
        'VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000) '
        "SELECT x,x%2,x,x%5,'payload-'||x FROM n");
    await db.execute('CREATE INDEX broad ON items(a,c)');
    await db.execute('CREATE INDEX selective ON items(b)');
    return db;
  }

  Future<(SqliteDatabase, _CountingStorage)> open(
      MutableSqliteDatabase db) async {
    final storage = _CountingStorage(MemoryStorageBackend());
    await storage.write(0, db.exportImage());
    final reader =
        await SqliteDatabase.openReadOnly(storage, functions: db.functions);
    addTearDown(reader.close);
    storage.reads = 0;
    return (reader, storage);
  }

  const sql = 'SELECT payload FROM items WHERE a=1 AND c=4 AND b=999';
  for (final encoding in [1, 2, 3]) {
    test(
        'ANALYZE ranks selective prefix over extra weak constraints encoding $encoding',
        () async {
      final db = await database(encoding: encoding);
      final (before, beforeStorage) = await open(db);
      expect(before.explain(sql).indexName, 'broad');
      expect((await before.query(sql)).rows, [
        ['payload-999']
      ]);
      final readsBefore = beforeStorage.reads;
      await db.execute('ANALYZE');
      final (after, afterStorage) = await open(db);
      expect(after.explain(sql).indexName, 'selective');
      expect((await after.query(sql)).rows, [
        ['payload-999']
      ]);
      expect(afterStorage.reads, lessThan(readsBefore));
      expect((await db.query(sql)).rows, [
        ['payload-999']
      ]);
    });
  }

  test('range estimates preserve mandatory index and NOT INDEXED behavior',
      () async {
    final db = await database();
    await db.execute('ANALYZE items');
    final (reader, _) = await open(db);
    expect(
        reader
            .explain(
                'SELECT payload FROM items WHERE a=1 AND c>=4 AND c<=4 AND b=999')
            .indexName,
        'selective');
    expect(
        reader
            .explain(
                'SELECT payload FROM items INDEXED BY broad WHERE a=1 AND c=4 AND b=999')
            .indexName,
        'broad');
    expect(
        reader
            .explain(
                'SELECT payload FROM items NOT INDEXED WHERE a=1 AND c=4 AND b=999')
            .access,
        'table-scan');
    expect(
        (await reader.query(
                'SELECT payload FROM items INDEXED BY broad WHERE a=1 AND c=4 AND b=999'))
            .rows,
        [
          ['payload-999']
        ]);
    expect(
        (await reader.query(
                'SELECT payload FROM items NOT INDEXED WHERE a=1 AND c=4 AND b=999'))
            .rows,
        [
          ['payload-999']
        ]);
  });

  test('partial and expression index statistics keep predicate proofs',
      () async {
    final db = await database();
    await db.execute('CREATE INDEX small ON items(a) WHERE b>=990');
    await db.execute('CREATE INDEX expression_broad ON items(abs(a),c)');
    await db.execute('CREATE INDEX expression_selective ON items(b+0)');
    await db.execute('ANALYZE');
    final (reader, _) = await open(db);
    const partial = 'SELECT payload FROM items WHERE a=1 AND b>=990';
    expect(reader.explain(partial).indexName, 'small');
    expect((await reader.query(partial)).rows, [
      for (var n = 991; n <= 999; n += 2) ['payload-$n']
    ]);
    expect(reader.explain('SELECT payload FROM items WHERE a=1').indexName,
        'broad');
    await expectLater(
        reader.query('SELECT payload FROM items INDEXED BY small WHERE a=1'),
        throwsA(isA<SqlException>()));
    const expression =
        'SELECT payload FROM items WHERE abs(a)=1 AND c=4 AND b+0=999';
    expect(reader.explain(expression).indexName, 'expression_selective');
    expect((await reader.query(expression)).rows, [
      ['payload-999']
    ]);
  });

  test(
      'invalid, duplicate and stale statistics fall back without omitting rows',
      () async {
    final db = await database();
    await db.execute('ANALYZE');
    for (final value in [
      'not statistics',
      '-1 1',
      '1000 -1',
      '1 2',
      '1000 1e0',
      '1000 0',
      '999999999999999999999999 1',
      '1000 1 weirdflag',
      '',
      'x' * 65537
    ]) {
      await db.execute('UPDATE sqlite_stat1 SET stat=?', [value]);
      final (reader, _) = await open(db);
      expect(reader.explain(sql).indexName, 'broad',
          reason: value.substring(0, value.length > 60 ? 60 : value.length));
      expect((await reader.query(sql)).rows, [
        ['payload-999']
      ]);
    }
    await db.execute('ANALYZE');
    await db.execute('INSERT INTO sqlite_stat1 SELECT * FROM sqlite_stat1');
    final (duplicate, _) = await open(db);
    expect(duplicate.explain(sql).indexName, 'broad');
    expect((await duplicate.query(sql)).rows, [
      ['payload-999']
    ]);
    await db.execute('ANALYZE');
    await db.execute('ALTER TABLE items RENAME TO renamed');
    final (renamed, _) = await open(db);
    final renamedSql = sql.replaceFirst('items', 'renamed');
    expect(renamed.explain(renamedSql).indexName, 'broad');
    expect((await renamed.query(renamedSql)).rows, [
      ['payload-999']
    ]);
  });

  test('valid stale estimates affect costs only and never result membership',
      () async {
    final db = await database();
    await db.execute('ANALYZE');
    await db
        .execute("UPDATE sqlite_stat1 SET stat='0 0' WHERE idx='selective'");
    final (reader, _) = await open(db);
    expect(reader.explain(sql).indexName, 'selective');
    expect((await reader.query(sql)).rows, [
      ['payload-999']
    ]);
    await db
        .execute("UPDATE sqlite_stat1 SET stat='1000 1 1' WHERE idx='broad'");
    await db.execute(
        "UPDATE sqlite_stat1 SET stat='1000 1000' WHERE idx='selective'");
    final (changed, _) = await open(db);
    expect(changed.explain(sql).indexName, 'broad');
    expect((await changed.query(sql)).rows, [
      ['payload-999']
    ]);
  });

  test('opening statistics never invokes scalar callbacks', () async {
    final db = await database();
    await db.execute('ANALYZE');
    await db.execute("UPDATE sqlite_stat1 SET stat='probe()'");
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      throw StateError('Stats invoked callback');
    });
    final (reader, _) = await open(db);
    expect(reader.explain(sql).indexName, 'broad');
    expect((await reader.query(sql)).rows, [
      ['payload-999']
    ]);
    expect(calls, 0);
  });

  test(
      'logical statistics faults fall back but malformed physical pages reject',
      () async {
    final db = await database();
    await db.execute('ANALYZE');
    await db.execute('UPDATE sqlite_stat1 SET stat=123');
    final (logical, _) = await open(db);
    expect(logical.explain(sql).indexName, 'broad');
    expect((await logical.query(sql)).rows, [
      ['payload-999']
    ]);
    final root = logical.catalog.entries
        .firstWhere((entry) => entry.name == 'sqlite_stat1')
        .rootPage;
    final damaged = db.exportImage();
    damaged[(root - 1) * 512] = 0;
    final storage = MemoryStorageBackend();
    await storage.write(0, damaged);
    await expectLater(
        SqliteDatabase.openReadOnly(storage), throwsA(isA<FormatException>()));
  });
}
