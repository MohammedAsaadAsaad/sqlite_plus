import 'dart:math';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('bounded selection equals complete ordering, encoding=$encoding',
        () async {
      final db = await openInMemory(encoding: encoding);
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY,k INTEGER,s TEXT COLLATE NOCASE)');
        final random = Random(719);
        await db.execute('INSERT INTO t VALUES ${[
          for (var i = 1; i <= 240; i++)
            "($i,${i % 11 == 0 ? 'NULL' : random.nextInt(31)},'${[
              'a',
              'A',
              'ب',
              'z'
            ][i % 4]}')"
        ].join(',')}');
        for (final shape in [
          'SELECT id,k,s FROM t',
          'SELECT DISTINCT k,s FROM t',
          'SELECT k,count(*) AS n FROM t GROUP BY k',
          'SELECT id,k,row_number() OVER(ORDER BY id) AS n FROM t',
          'WITH c AS MATERIALIZED(SELECT * FROM t) SELECT id,k,s FROM c',
          'SELECT a.id,a.k,a.s FROM t AS a JOIN t AS b ON a.id=b.id',
        ]) {
          final order = shape.contains('DISTINCT')
              ? 'k,s COLLATE RTRIM DESC'
              : shape.contains('GROUP BY')
                  ? 'k DESC NULLS FIRST'
                  : 'k DESC NULLS LAST,1';
          final full = (await db.query('$shape ORDER BY $order')).rows;
          for (final k in [0, 1, 31, 32, 33, 64, 256, -1]) {
            for (final offset in [0, 5, 250, -1]) {
              final result = (await db.query(
                      '$shape ORDER BY $order LIMIT ? OFFSET ?', [k, offset]))
                  .rows;
              final rest = full.skip(offset < 0 ? 0 : offset);
              expect(result, k < 0 ? rest.toList() : rest.take(k).toList(),
                  reason: '$shape k=$k offset=$offset');
            }
          }
        }
        final read = await db
            .prepare('SELECT id,k FROM t ORDER BY k,id LIMIT ? OFFSET ?');
        for (final k in [1, 31, 32, 33, 64]) {
          final expected = (await db.query('SELECT id,k FROM t ORDER BY k,id'))
              .rows
              .skip(4)
              .take(k)
              .toList();
          expect((await read.query([k, 4])).rows, expected);
        }
        await read.close();
      } finally {
        await db.close();
      }
    });
  }
  test('equal sort keys retain earliest input rows at heap boundary', () async {
    final db = await openInMemory();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,k INTEGER)');
      await db.execute('INSERT INTO t VALUES ${[
        for (var i = 1; i <= 200; i++) '($i,1)'
      ].join(',')}');
      expect(
          (await db.query('SELECT id FROM t ORDER BY k LIMIT 32 OFFSET 5'))
              .rows,
          [
            for (var i = 6; i <= 37; i++) [BigInt.from(i)]
          ]);
    } finally {
      await db.close();
    }
  });
}
