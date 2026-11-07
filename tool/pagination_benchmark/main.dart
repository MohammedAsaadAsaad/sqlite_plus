import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 10000 : int.parse(args.first);
  final db = await openInMemory();
  try {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= count; i++) '($i,${i % 11})'
    ].join(',')}');
    final imageBefore = db.exportImage();
    final offset = count * 9 ~/ 10;
    final anchor =
        await db.page(table: 'items', keyColumns: ['id'], size: offset);
    final cursor = PageCursor.parse(anchor.nextCursor!.encode());
    const size = 30;
    final records = <Map<String, Object?>>[];
    String? pageSql;
    List<Object?>? pageParameters;
    final pager = SqlPagination((sql, parameters) {
      pageSql = sql;
      pageParameters = parameters;
      return db.query(sql, parameters);
    });
    for (var iteration = 0; iteration < 7; iteration++) {
      for (final variant
          in iteration.isEven ? ['offset', 'cursor'] : ['cursor', 'offset']) {
        final clock = Stopwatch()..start();
        final List<Object?> ids;
        if (variant == 'offset') {
          ids = (await db.query(
                  'SELECT * FROM items ORDER BY id LIMIT ? OFFSET ?',
                  [size, offset]))
              .rows
              .map((r) => r.first)
              .toList();
        } else {
          ids = (await pager.page(
                  table: 'items',
                  keyColumns: ['id'],
                  size: size,
                  after: cursor))
              .items
              .map((r) => r['id'])
              .toList();
        }
        clock.stop();
        if (ids.length != size ||
            ids.first != BigInt.from(offset + 1) ||
            ids.last != BigInt.from(offset + size)) {
          throw StateError('Page checksum');
        }
        records.add({
          'iteration': iteration,
          'variant': variant,
          'microseconds': clock.elapsedMicroseconds
        });
      }
    }
    final imageAfter = db.exportImage();
    final beforeHash = sha256.convert(imageBefore).toString();
    if (sha256.convert(imageAfter).toString() != beforeHash) {
      throw StateError('Paging changed image');
    }
    // EXPLAIN QUERY PLAN currently rejects binds. This fixed workload has
    // integer parameters only; literalize those for the diagnostic, not timing.
    if (!pageParameters!.every((v) => v is BigInt || v is int)) {
      throw StateError('Expected integer-only benchmark binds');
    }
    var parameterIndex = 0;
    final explainSql = pageSql!.replaceAllMapped(
        RegExp(r'\?'), (_) => pageParameters![parameterIndex++].toString());
    final explain = await db.query('EXPLAIN QUERY PLAN $explainSql');
    print(jsonEncode({
      'rows': count,
      'offset': offset,
      'size': size,
      'records': records,
      'image_bytes': imageAfter.length,
      'image_sha256': beforeHash,
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss,
      'cursor_sql': pageSql,
      'plan': explain.rows
          .map((r) => r.map((v) => v is BigInt ? v.toString() : v).toList())
          .toList()
    }));
  } finally {
    await db.close();
  }
}
