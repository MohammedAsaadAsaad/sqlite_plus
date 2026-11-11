import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import '../../packages/sqlite_plus_orm/example/prepared.dart' as model;

Future<void> main(List<String> args) async {
  final mode = args[0];
  final prepared = args[1] == 'prepared';
  const count = 3000;
  final db = await openInMemory();
  await db.execute(
      'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
  await db.execute("INSERT INTO products VALUES ${[
    for (var i = 1; i <= 100; i++) "($i,'p$i',$i)"
  ].join(',')}");
  db.exportImage();
  final context = DbContext(
      MutableDatabaseConnection(db), DbModel([model.mapping]),
      preparedQueryCacheSize: args[1] == 'cache' ? 16 : 0);
  final parameter = QueryParameter<int>('minimum');
  final query = context
      .set(model.mapping)
      .query
      .where(model.price.gteParameter(parameter))
      .asNoTracking();
  final typed = mode == 'orm' && prepared ? await query.prepare() : null;
  const sql =
      'SELECT id,price FROM products WHERE price>=? AND id<=? ORDER BY id LIMIT ?';
  const updateSql = 'UPDATE products SET price=? WHERE id=? AND price>=0';
  final statement = mode == 'orm' || !prepared
      ? null
      : await db.prepare(mode == 'update' ? updateSql : sql);
  if (mode == 'update') await db.execute('BEGIN');
  final timer = Stopwatch()..start();
  var checksum = 0;
  for (var i = 0; i < count; i++) {
    final minimum = i % 90 + 1;
    if (mode == 'orm') {
      final rows = typed == null
          ? await context
              .set(model.mapping)
              .query
              .where(model.price.gte(minimum))
              .asNoTracking()
              .toList()
          : await typed.toList(parameters: {parameter: minimum});
      checksum += rows.fold<int>(0, (sum, row) => sum + row.price);
    } else if (mode == 'update') {
      final result = statement == null
          ? await db.execute(updateSql, [minimum, i % 100 + 1])
          : await statement.execute([minimum, i % 100 + 1]);
      checksum += result.changes;
    } else {
      final rows = statement == null
          ? await db.query(sql, [minimum, 100, 5])
          : await statement.query([minimum, 100, 5]);
      checksum += rows.rows.fold<int>(
          0,
          (sum, row) =>
              sum + (row[0] as BigInt).toInt() + (row[1] as BigInt).toInt());
    }
  }
  timer.stop();
  if (mode == 'update') await db.execute('COMMIT');
  print(jsonEncode({
    'mode': mode,
    'variant': args[1],
    'operations': count,
    'duration_us': timer.elapsedMicroseconds,
    'checksum': checksum,
    'image_bytes': db.exportImage().length,
    'select_parses': statement?.selectParseCount,
    'expression_parses': statement?.expressionParseCount,
    'expression_reuse': statement?.expressionReuseCount,
    'logical_sha256': sha256
        .convert(utf8.encode(
            (await db.query('SELECT id,price FROM products ORDER BY id'))
                .rows
                .toString()))
        .toString(),
    'rss': ProcessInfo.currentRss
  }));
  await statement?.close();
  await typed?.close();
  await context.close();
  await db.close();
}
