import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('forward/backward keyset pages match pinned SQLite ordering', () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    const schema =
        'CREATE TABLE t(id INTEGER PRIMARY KEY,n,label TEXT COLLATE NOCASE)';
    const seed =
        "INSERT INTO t VALUES(-9223372036854775808,NULL,'A'),(2,1,'a'),(3,1.5,'B'),(4,1,'b'),(5,'x','C'),(6,X'00','c'),(9223372036854775807,NULL,'D')";
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(schema);
    await db.execute(seed);
    for (final indexed in [false, true]) {
      if (indexed) {
        await db.execute('CREATE INDEX ix ON t(n DESC,label ASC,id)');
      }
      for (final desc in [false, true]) {
        for (final nulls in [false, true]) {
          for (final collation in [null, 'BINARY', 'NOCASE', 'RTRIM']) {
            final order = [
              PageOrder('n', descending: desc, nullsFirst: nulls),
              PageOrder('label', collation: collation)
            ];
            final native = await Process.run(cli, [
              ':memory:',
              '$schema;$seed;SELECT id FROM t ORDER BY n ${desc ? 'DESC' : 'ASC'} NULLS ${nulls ? 'FIRST' : 'LAST'},label ${collation == null ? '' : 'COLLATE $collation'},id;'
            ]);
            expect(native.exitCode, 0, reason: native.stderr.toString());
            final expected = native.stdout.toString().trim().split('\n');
            final pages = <SqlPage<Map<String, Object?>>>[];
            PageCursor? cursor;
            do {
              final p = await db.page(
                  table: 't',
                  keyColumns: ['id'],
                  orderBy: order,
                  size: 2,
                  after: cursor);
              pages.add(p);
              cursor = p.nextCursor;
            } while (cursor != null);
            expect([
              for (final p in pages) ...p.items.map((r) => r['id'].toString())
            ], expected);
            for (var i = pages.length - 1; i > 0; i--) {
              final previous = await db.page(
                  table: 't',
                  keyColumns: ['id'],
                  orderBy: order,
                  size: 2,
                  before: pages[i].previousCursor);
              expect(previous.items, pages[i - 1].items);
            }
          }
        }
      }
    }
  });
}
