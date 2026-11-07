import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

Future<void> runWorkload(List<String> args,
    {Future<void> Function(MutableSqliteDatabase)? configure}) async {
  final count = args.isEmpty ? 1000 : int.parse(args.first);
  final db = await openInMemory();
  final timings = <String, int>{};
  Future<void> measure(String name, Future<void> Function() action) async {
    final clock = Stopwatch()..start();
    await action();
    timings[name] = clock.elapsedMicroseconds;
  }

  try {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,body TEXT,n INTEGER)');
    if (configure != null) await configure(db);
    await measure('insert', () async {
      for (var start = 0; start < count; start += 500) {
        final end = start + 500 < count ? start + 500 : count;
        await db.execute(
            'INSERT INTO items VALUES ${List.filled(end - start, '(?,?,?)').join(',')}',
            [
              for (var i = start; i < end; i++) ...[
                i + 1,
                i % 50 == 0 ? 'needle حليب $i' : 'milk منتج $i',
                i
              ],
            ]);
      }
    });
    await measure('point_500', () async {
      for (var i = 0; i < 500; i++) {
        final r = await db
            .query('SELECT body,n FROM items WHERE id=?', [i % count + 1]);
        if (r.rows.length != 1) throw StateError('Missing row');
      }
    });
    await measure('range_50', () async {
      for (var i = 0; i < 50; i++)
        await db.query(
            'SELECT id,n FROM items WHERE id>=? AND id<?', [i + 1, i + 21]);
    });
    await measure('update_batch_200', () async {
      await db.execute('BEGIN');
      for (var i = 0; i < 200; i++)
        await db.execute(
            'UPDATE items SET n=? WHERE id=?', [count + i, i % count + 1]);
      await db.execute('COMMIT');
    });
    await measure('update_auto_20', () async {
      for (var i = 0; i < 20; i++)
        await db.execute(
            'UPDATE items SET n=? WHERE id=?', [2 * count + i, i % count + 1]);
    });
    final search = await SqlitePlusSearch.open(database: db);
    await measure(
        'search_index',
        () => search.indexTable(
            table: 'items', primaryKey: 'id', textColumns: ['body']));
    await search.search('needle',
        table: 'items', ranking: const SearchRankingPolicy());
    await measure('search_20', () async {
      for (var i = 0; i < 20; i++) {
        final r = await search.search('needle',
            table: 'items', ranking: const SearchRankingPolicy());
        if (r.total != (count / 50).ceil())
          throw StateError('Changed search results');
      }
    });
    late List<int> image;
    await measure('export', () async {
      image = db.exportImage();
    });
    print(jsonEncode({
      'rows': count,
      'timings_us': timings,
      'image_bytes': image.length,
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
  }
}
