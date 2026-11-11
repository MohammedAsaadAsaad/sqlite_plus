import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';

final class ReadSample {
  ReadSample(this.result, this.durationUs, [this.metadata]);
  final QueryResult result;
  final int durationUs;
  final Map<String, Object?> Function()? metadata;
}

typedef Reader = Future<ReadSample> Function(
    Object, String, List<Object?>, bool, int);

Future<void> workload(List<String> args, Reader run) async {
  if (args[0] == 'seed') {
    final rows = int.parse(args[2]), indexes = int.parse(args[3]);
    final db = await openInMemory();
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,score INTEGER,flag INTEGER,payload TEXT)');
    await db.execute('BEGIN');
    for (var start = 1; start <= rows; start += 1000) {
      await db.execute("INSERT INTO items VALUES ${[
        for (var i = start; i < start + 1000 && i <= rows; i++)
          "($i,${(i * 7919) % rows},${i % 7},'payload-${i.toString().padLeft(8, '0')}')"
      ].join(',')}");
    }
    await db.execute('COMMIT');
    for (var i = 0; i < indexes; i++) {
      await db.execute('CREATE INDEX idx_$i ON items(flag,score)');
    }
    if (indexes > 0) await db.execute('ANALYZE');
    final image = db.exportImage();
    await File(args[1]).writeAsBytes(image);
    await db.close();
    print(jsonEncode({
      'path': args[1],
      'rows': rows,
      'indexes': indexes,
      'bytes': image.length,
      'sha256': sha256.convert(image).toString()
    }));
    return;
  }
  final path = args[0], mode = args[1], enabled = args[2] == 'on';
  final repeats = int.parse(args[3]),
      capacity = int.parse(args[4]),
      rows = int.parse(args[5]);
  final image = await File(path).readAsBytes();
  Object db = args.length > 6 && args[6] == 'mutable'
      ? await MutableSqliteDatabase.fromImage(image)
      : await SqliteDatabase.openReadOnly(ByteImageStorage(image));
  final pager = db is SqliteDatabase ? db : null;
  SqlInspector? inspector;
  if (args.length > 6 && args[6] == 'inspected') {
    inspector = SqlInspector();
    db = inspector.readOnly(pager!);
  }
  final sql = switch (mode) {
    'point' => 'SELECT payload FROM items WHERE id=?',
    'scan' => 'SELECT id FROM items WHERE score>=?',
    'early' => 'SELECT id FROM items LIMIT ? OFFSET ?',
    'index' =>
      'SELECT id,score FROM items WHERE flag=? AND score>=? ORDER BY score,id LIMIT 32',
    _ => 'SELECT id,payload FROM items WHERE flag>=? ORDER BY score,id LIMIT ?',
  };
  var queryUs = 0, returned = 0;
  final hashes = <String>[];
  Map<String, Object?>? last;
  final pageBefore = pager?.pagesRead;
  for (var i = 0; i < repeats; i++) {
    final params = switch (mode) {
      'point' => <Object?>[i % rows + 1],
      'scan' => <Object?>[rows ~/ 2 + i % 3],
      'early' => <Object?>[1, i % 7],
      'index' => <Object?>[i % 7, rows ~/ 2],
      _ => <Object?>[0, 100],
    };
    final pageStart = pager?.pagesRead;
    final sample = await run(db, sql, params, enabled, capacity);
    queryUs += sample.durationUs;
    returned += sample.result.rows.length;
    hashes.add(
        sha256.convert(utf8.encode(sample.result.rows.toString())).toString());
    last = sample.metadata?.call();
    if (last != null) {
      if (last['rowsReturned'] != sample.result.rows.length)
        throw StateError('Output counter');
      if (pager != null && last['pageReads'] != pager.pagesRead - pageStart!)
        throw StateError('Pager counter');
      if ((last['decisions'] as List).length > capacity)
        throw StateError('Trace bound');
      if (jsonEncode(last).contains(sql))
        throw StateError('Unexpected SQL capture');
    }
  }
  final pages = pager == null ? null : pager.pagesRead - pageBefore!;
  print(jsonEncode({
    'mode': mode,
    'adapter': args.length > 6 ? args[6] : 'reader',
    'enabled': enabled,
    'repeats': repeats,
    'max_candidates': capacity,
    'duration_us': queryUs,
    'hash': sha256.convert(utf8.encode(hashes.join(','))).toString(),
    'result_rows': returned,
    'page_reads': pages,
    'last_report': last,
    'image_bytes': image.length,
    'rss': ProcessInfo.currentRss,
    'peak_rss': ProcessInfo.maxRss
  }));
  if (pager != null) {
    await pager.close();
  } else {
    await (db as MutableSqliteDatabase).close();
  }
  inspector?.close();
}

Future<QueryResult> ordinaryRead(Object db, String sql, List<Object?> args) {
  if (db is SqliteDatabase) return db.query(sql, args);
  if (db is InspectedConnection) return db.query(sql, args);
  return (db as MutableSqliteDatabase).query(sql, args);
}
