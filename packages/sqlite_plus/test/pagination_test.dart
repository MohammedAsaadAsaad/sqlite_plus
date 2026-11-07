import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  for (final descending in [false, true]) {
    for (final nulls in [null, false, true]) {
      test('multi-column traversal and reverse desc=$descending nulls=$nulls',
          () async {
        final db = await openInMemory();
        addTearDown(db.close);
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER,label TEXT)');
        await db.execute(
            "INSERT INTO t VALUES(1,NULL,'a'),(2,2,'b'),(3,1,'c'),(4,NULL,'d'),(5,2,'e'),(6,3,'f'),(7,1,'g')");
        final order = [
          PageOrder('n', descending: descending, nullsFirst: nulls),
          PageOrder('label', descending: !descending)
        ];
        final expected = (await db.query(
                'SELECT id FROM t ORDER BY n ${descending ? 'DESC' : 'ASC'} ${nulls == null ? '' : nulls ? 'NULLS FIRST' : 'NULLS LAST'},label ${descending ? 'ASC' : 'DESC'},id'))
            .rows
            .map((r) => r.single)
            .toList();
        final pages = <SqlPage<Map<String, Object?>>>[];
        PageCursor? after;
        final ids = <Object?>[];
        do {
          final page = await db.page(
              table: 't',
              keyColumns: ['id'],
              orderBy: order,
              size: 2,
              after: after);
          pages.add(page);
          ids.addAll(page.items.map((r) => r['id']));
          after = page.nextCursor == null
              ? null
              : PageCursor.parse(page.nextCursor!.encode());
        } while (after != null);
        expect(ids, expected);
        expect(pages.first.hasPreviousPage, isFalse);
        expect(pages.last.hasNextPage, isFalse);
        for (var i = pages.length - 1; i > 0; i--) {
          final prior = await db.page(
              table: 't',
              keyColumns: ['id'],
              orderBy: order,
              size: 2,
              before: pages[i].previousCursor);
          expect(prior.items, pages[i - 1].items);
          expect(prior.hasPreviousPage, i > 1);
        }
      });
    }
  }

  test('collation tie groups, composite keys and mixed storage classes',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(a INTEGER,b TEXT COLLATE NOCASE,v,PRIMARY KEY(a,b))');
    await db.execute(
        "INSERT INTO t VALUES(1,'a',NULL),(1,'B',1),(2,'c',1.5),(2,'D','x'),(3,'e',X'00'),(3,'F',X'01')");
    for (final collation in [null, 'BINARY', 'NOCASE', 'RTRIM']) {
      for (final col in ['b', 'v']) {
        final order = [PageOrder(col, collation: collation)];
        final ids = <String>[];
        PageCursor? after;
        do {
          final p = await db.page(
              table: 't',
              keyColumns: ['a', 'b'],
              orderBy: order,
              size: 1,
              after: after);
          ids.addAll(p.items.map((r) => '${r['a']}:${r['b']}'));
          after = p.nextCursor == null
              ? null
              : PageCursor.parse(p.nextCursor!.encode());
        } while (after != null);
        final expected = await db.query(
            'SELECT a,b FROM t ORDER BY "$col" ${collation == null ? '' : 'COLLATE $collation'},a${col == 'b' ? '' : ',b'}');
        expect(ids, [for (final row in expected.rows) '${row[0]}:${row[1]}']);
      }
    }
  });

  test('explicit key collation keeps a binary tie-breaker', () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id TEXT PRIMARY KEY)');
    await db.execute("INSERT INTO t VALUES('a'),('A'),('b')");
    final order = [PageOrder('id', collation: 'NOCASE')];
    final values = <Object?>[];
    PageCursor? cursor;
    do {
      final page = await db.page(
          table: 't',
          keyColumns: ['id'],
          orderBy: order,
          size: 1,
          after: cursor);
      values.addAll(page.items.map((r) => r['id']));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(values, ['A', 'a', 'b']);
  });

  test('64-bit keys, BLOB cursor isolation, projection and read-only API',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,b BLOB)');
    for (final id in [
      -(BigInt.one << 63),
      BigInt.zero,
      (BigInt.one << 63) - BigInt.one
    ]) {
      await db.execute('INSERT INTO t VALUES(?,?)', [
        id,
        Uint8List.fromList([7])
      ]);
    }
    final order = [PageOrder('b')];
    final first =
        await db.page(table: 't', keyColumns: ['id'], orderBy: order, size: 1);
    (first.items.single['b'] as Uint8List)[0] = 255;
    final second = await db.page(
        table: 't',
        keyColumns: ['id'],
        orderBy: order,
        size: 1,
        after: PageCursor.parse(first.nextCursor!.encode()));
    expect(second.items.single['id'], BigInt.zero);
    final image = db.exportImage();
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final readonly = await SqliteDatabase.openReadOnly(storage);
    addTearDown(readonly.close);
    expect(
        (await readonly.page(
                table: 't', keyColumns: ['id'], size: 1, columns: ['id']))
            .items
            .single['id'],
        -(BigInt.one << 63));
  });

  test(
      'insert/delete before the boundary and removal of anchor do not shift pages',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES(1),(2),(3),(4)');
    final p = await db.page(table: 't', keyColumns: ['id'], size: 2);
    await db.execute('INSERT INTO t VALUES(0)');
    await db.execute('DELETE FROM t WHERE id IN (1,2)');
    final next = await db.page(
        table: 't', keyColumns: ['id'], after: p.nextCursor, size: 2);
    expect(next.items.map((r) => r['id']), [BigInt.from(3), BigInt.from(4)]);
  });

  test('scope, shape, key, size and malformed cursor validation', () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,1),(2,1),(3,2)');
    final p = await db.page(
        table: 't',
        keyColumns: ['id'],
        where: 'n>?',
        parameters: [0],
        size: 1,
        cursorScope: 'tenant-a');
    for (final action in <Future<Object?> Function()>[
      () => db.page(
          table: 't',
          keyColumns: ['id'],
          where: 'n>?',
          parameters: [1],
          size: 1,
          cursorScope: 'tenant-a',
          after: p.nextCursor),
      () => db.page(
          table: 't',
          keyColumns: ['id'],
          where: 'n>?',
          parameters: [0],
          size: 1,
          cursorScope: 'tenant-b',
          after: p.nextCursor),
      () => db.page(table: 't', keyColumns: ['id'], size: 0),
      () => db.page(table: 't', keyColumns: []),
      () => db.page(table: 't', keyColumns: ['id'], columns: ['n']),
      () => db.page(
          table: 't',
          keyColumns: ['id'],
          orderBy: [PageOrder('n'), PageOrder('N')]),
      () => db.page(
          table: 't',
          keyColumns: ['id'],
          after: p.nextCursor,
          before: p.nextCursor),
      () => db.page(table: 't', keyColumns: ['id'], parameters: [1]),
      () => db.page(table: 't', keyColumns: ['id'], where: ' '),
    ]) {
      await expectLater(action(), throwsArgumentError);
    }
    await db.execute('CREATE TABLE bad(id)');
    await db.execute('INSERT INTO bad VALUES(NULL),(1),(1)');
    await expectLater(
        db.page(table: 'bad', keyColumns: ['id']), throwsStateError);
    for (final token in [
      '',
      '%%%',
      base64Url.encode(utf8.encode('[2,"scope",[]]')),
      'x' * 65537
    ]) {
      expect(() => PageCursor.parse(token), throwsArgumentError);
    }
    for (final value in [
      ['r', 'NaN'],
      ['r', 'Infinity'],
      ['i', '9223372036854775808'],
      ['b', '%'],
      ['x', 'unknown'],
      ['n', 'extra']
    ]) {
      final token = base64Url.encode(utf8.encode(jsonEncode([
        1,
        '0' * 64,
        [value]
      ])));
      expect(() => PageCursor.parse(token), throwsArgumentError);
    }
  });

  test('single SQL statement, bound limits/values and quoted identifiers',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE "odd table"("key" INTEGER PRIMARY KEY,"odd""name" TEXT)');
    await db.execute(
        'INSERT INTO "odd table" VALUES(1,?),(2,?)', ["x' OR 1=1 --", 'b']);
    var executions = 0;
    final pager = SqlPagination((sql, args) {
      executions++;
      expect(sql, isNot(contains('OFFSET')));
      return db.query(sql, args);
    });
    final page = await pager.page(
        table: 'odd table',
        keyColumns: ['key'],
        columns: ['key', 'odd"name'],
        where: '"odd""name"=?',
        parameters: ["x' OR 1=1 --"]);
    expect(page.items.length, 1);
    expect(executions, 1);
    expect(() => page.items.clear(), throwsUnsupportedError);
  });
}
