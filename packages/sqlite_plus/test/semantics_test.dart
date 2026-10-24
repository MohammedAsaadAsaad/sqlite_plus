import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;
import 'function_registry_test.dart' show SumValues;

final class CountedStorage implements StorageBackend {
  CountedStorage(this.inner);
  final StorageBackend inner;
  int reads = 0;
  @override
  Future<int> read(int offset, Uint8List bytes) {
    reads++;
    return inner.read(offset, bytes);
  }

  @override
  Future<void> write(int offset, Uint8List bytes) => inner.write(offset, bytes);
  @override
  Future<void> truncate(int size) => inner.truncate(size);
  @override
  Future<int> length() => inner.length();
  @override
  Future<void> sync() => inner.sync();
  @override
  Future<void> close() => inner.close();
}

void main() {
  final cases =
      jsonDecode(File('test/fixtures/semantics_oracle.json').readAsStringSync())
          as List;
  for (final size in [512, 4096, 65536]) {
    group('M6 differential $size', () {
      late SqliteDatabase database;
      setUpAll(() async {
        database = await SqliteDatabase.openReadOnly(
            await ReadOnlyFileStorageBackend.open(
                'test/fixtures/sqlite-$size.db'));
        database.functions.registerScalar(
            'dart_twice',
            1,
            (args) => args.single == null
                ? null
                : (args.single as BigInt) * BigInt.two);
        database.functions.registerAggregate('dart_sum', 1, SumValues.new);
      });
      tearDownAll(() => database.close());
      for (final entry in cases.where((c) => c['file'] == 'sqlite-$size.db')) {
        test(entry['sql'] as String, () async {
          var counter = 0;
          database.functions
              .registerScalar('dart_counter', 0, (args) => ++counter);
          if (entry.containsKey('error')) {
            await expectLater(
                database.query(entry['sql'] as String,
                    (entry['parameters'] as List).map(expectedValue).toList()),
                throwsA(isA<SqlException>()));
            return;
          }
          final result = await database.query(entry['sql'] as String,
              (entry['parameters'] as List).map(expectedValue).toList());
          expect(result.columns, entry['columns']);
          expect(
              result.rows,
              (entry['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList());
        });
      }
    });
  }
  test('secondary index prefix descent prunes pages and retains duplicate keys',
      () async {
    final mutable = await MutableSqliteDatabase.create(pageSize: 512);
    await mutable.execute(
        'CREATE TABLE indexed(id INTEGER PRIMARY KEY,k INT,payload TEXT)');
    await mutable.execute(
        "INSERT INTO indexed WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) SELECT x,x%100,'payload-'||x FROM n");
    await mutable.execute('CREATE INDEX indexed_k ON indexed(k DESC,id)');
    await mutable
        .execute('CREATE INDEX indexed_payload ON indexed(k,payload DESC)');
    final storage = CountedStorage(MemoryStorageBackend());
    await storage.write(0, mutable.exportImage());
    await mutable.close();
    final db = await SqliteDatabase.openReadOnly(storage);
    addTearDown(db.close);
    expect(db.explain('SELECT id FROM indexed WHERE k=7').access,
        'secondary-index-lookup');
    storage.reads = 0;
    final result =
        await db.query('SELECT id FROM indexed WHERE k=7 ORDER BY id');
    final reads = storage.reads;
    storage.reads = 0;
    final scan =
        await db.query('SELECT id FROM indexed WHERE +k=7 ORDER BY id');
    expect(result.rows, scan.rows);
    expect(result.rows.length, 10);
    expect(reads, lessThan(storage.reads));
    for (final key in [-1, 0, 99, 100]) {
      expect(
          (await db
                  .query('SELECT id FROM indexed WHERE k=? ORDER BY id', [key]))
              .rows,
          (await db.query(
                  'SELECT id FROM indexed WHERE +k=? ORDER BY id', [key]))
              .rows);
    }
    expect(
        (await db.query('SELECT id FROM indexed WHERE k=NULL')).rows, isEmpty);
  });
  test(
      'range and multi-column plans match scans across inclusive, empty and reversed bounds',
      () async {
    final mutable = await MutableSqliteDatabase.create(pageSize: 512);
    await mutable
        .execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,b TEXT)');
    await mutable.execute(
        "INSERT INTO t WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<300) SELECT x,x%10,'v'||x FROM n");
    await mutable.execute('CREATE INDEX first_a ON t(a DESC)');
    await mutable.execute('CREATE INDEX second_ab ON t(a,b DESC)');
    final storage = CountedStorage(MemoryStorageBackend());
    await storage.write(0, mutable.exportImage());
    await mutable.close();
    final db = await SqliteDatabase.openReadOnly(storage);
    addTearDown(db.close);
    for (final predicate in [
      'id>10 AND id<=15',
      '10<id AND 15>=id',
      'id>1000',
      'id>=NULL',
      'id>15 AND id<10',
      'a>=3 AND a<5',
      "a=2 AND b>='v100' AND b<'v220'",
      'a>=3.5 AND a<4.5',
      'id>=-9223372036854775808 AND id<=9223372036854775807'
    ]) {
      final forced = predicate
          .replaceAll(RegExp(r'\bid\b'), '+id')
          .replaceAll(RegExp(r'\ba\b'), '+a')
          .replaceAll(RegExp(r'\bb\b'), '+b');
      expect(
          (await db.query('SELECT id FROM t WHERE $predicate ORDER BY id'))
              .rows,
          (await db.query('SELECT id FROM t WHERE $forced ORDER BY id')).rows,
          reason: predicate);
    }
    expect(db.explain("SELECT id FROM t WHERE a=2 AND b>='v100'").indexName,
        'second_ab');
    expect(db.explain('SELECT id FROM t WHERE id>10 AND id<15').access,
        'rowid-range');
    expect(db.explain('SELECT id FROM t WHERE a>=3 AND a<5').access,
        'secondary-index-range');
    storage.reads = 0;
    await db.query('SELECT id FROM t WHERE id>10 AND id<15');
    final reads = storage.reads;
    storage.reads = 0;
    await db.query('SELECT id FROM t WHERE +id>10 AND +id<15');
    expect(reads, lessThan(storage.reads));
    db.functions.registerScalar('callback', 0, (args) => 1);
    expect(db.explain('SELECT id FROM t WHERE id=callback()').access,
        'table-scan');
  });
  test('rowid point lookup reads fewer pages and explains chosen access',
      () async {
    final storage = CountedStorage(
        await ReadOnlyFileStorageBackend.open('test/fixtures/write.db'));
    final db = await SqliteDatabase.openReadOnly(storage);
    addTearDown(db.close);
    expect(db.explain('SELECT id FROM notes WHERE id=?', [1999]).access,
        'rowid-lookup');
    storage.reads = 0;
    final point = await db.query('SELECT id FROM notes WHERE id=?', [1999]);
    final pointReads = storage.reads;
    storage.reads = 0;
    final scan = await db.query('SELECT id FROM notes WHERE +id=?', [1999]);
    expect(point.rows, scan.rows);
    expect(pointReads, lessThan(storage.reads ~/ 10));
    expect(db.explain('SELECT id FROM notes WHERE +id=?', [1999]).access,
        'table-scan');
    expect((await db.query('SELECT id FROM notes WHERE id=-1')).rows, isEmpty);
  });
  test('aggregate misuse and unsupported metadata fail explicitly', () async {
    final db = await SqliteDatabase.openReadOnly(
        await ReadOnlyFileStorageBackend.open('test/fixtures/sqlite-512.db'));
    addTearDown(db.close);
    for (final sql in [
      'SELECT sum(count(*)) FROM sample',
      'SELECT id FROM sample WHERE count(*)>1',
      'SELECT count(*) FROM sample GROUP BY sum(id)',
      'SELECT count(*) FROM sample GROUP BY 0',
      'SELECT unknown_fn(1)',
      'SELECT abs()',
      'SELECT count(DISTINCT *) FROM sample',
      'PRAGMA page_size=1024',
      'PRAGMA unsupported',
      'SELECT abs(-9223372036854775808)'
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()),
          reason: sql);
    }
  });
  test('empty-table aggregate misuse in mutations does not silently succeed',
      () async {
    final db = await MutableSqliteDatabase.fromImage(
        File('test/fixtures/write.db').readAsBytesSync());
    addTearDown(db.close);
    await db.execute('DELETE FROM notes');
    final before = db.exportImage();
    for (final sql in [
      'UPDATE notes SET n=count(*)',
      'DELETE FROM notes WHERE count(*)>0',
      'INSERT INTO notes(value) VALUES(count(*))'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
  });
  test('primary-key search rejects corrupt leaf framing', () async {
    final bytes = File('test/fixtures/write.db').readAsBytesSync();
    var number = 2;
    final data = ByteData.sublistView(bytes);
    while (bytes[(number - 1) * 512] == 5) {
      final base = (number - 1) * 512;
      final cell = data.getUint16(base + 12);
      number = data.getUint32(base + cell);
    }
    final base = (number - 1) * 512;
    final cell = data.getUint16(base + 8);
    // Keep cell pointer in range but advertise a payload beyond the page end.
    bytes[base + cell] = 127;
    final memory = MemoryStorageBackend();
    await memory.write(0, bytes);
    final db = await SqliteDatabase.openReadOnly(memory);
    addTearDown(db.close);
    await expectLater(
        db.query('SELECT id FROM notes WHERE id=1'), throwsFormatException);
  });
  test('metadata preserves NOT NULL and reports signed pragma fields',
      () async {
    final bytes = File('test/fixtures/write.db').readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    data.setUint32(60, 0xffffffff);
    data.setUint32(68, 0x80000001);
    final memory = MemoryStorageBackend();
    await memory.write(0, bytes);
    final db = await SqliteDatabase.openReadOnly(memory);
    addTearDown(db.close);
    expect((await db.query('PRAGMA user_version')).rows, [
      [BigInt.from(-1)]
    ]);
    expect((await db.query('PRAGMA application_id')).rows, [
      [BigInt.from(-2147483647)]
    ]);
    expect((await db.query('PRAGMA table_info(guarded)')).rows, [
      [BigInt.zero, 'x', 'TEXT', BigInt.one, null, BigInt.zero]
    ]);
    final table = DatabaseCatalog.parseTable(
        'CREATE TABLE t(v varchar (20) DEFAULT (7), x INTEGER(1) PRIMARY KEY)',
        2);
    expect(table.columns.first.declaredType, 'varchar (20)');
    expect(table.columns.first.defaultSql, '7');
    expect(table.rowidAlias, isNull);
  });
  test('function output limits reject large allocations before expansion',
      () async {
    final db = await SqliteDatabase.openReadOnly(
        await ReadOnlyFileStorageBackend.open('test/fixtures/sqlite-512.db'));
    addTearDown(db.close);
    for (final sql in [
      'SELECT zeroblob(16777217)',
      'SELECT hex(zeroblob(8388609))'
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()));
    }
    await expectLater(db.query("SELECT replace('aa','a',?)", ['x' * 8388609]),
        throwsA(isA<SqlException>()));
  });
}
