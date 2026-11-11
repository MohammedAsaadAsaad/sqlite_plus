import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart'
    show ReadOnlyFileStorageBackend;

final class CountingStorage implements StorageBackend {
  CountingStorage(this.inner);
  final StorageBackend inner;
  int reads = 0, bytes = 0;
  @override
  Future<int> read(int offset, Uint8List target) async {
    reads++;
    final count = await inner.read(offset, target);
    bytes += count;
    return count;
  }

  @override
  Future<void> write(int offset, Uint8List value) => inner.write(offset, value);
  @override
  Future<void> truncate(int length) => inner.truncate(length);
  @override
  Future<int> length() => inner.length();
  @override
  Future<void> sync() => inner.sync();
  @override
  Future<void> close() => inner.close();
}

Future<void> main(List<String> args) async {
  if (args[0] == 'seed') {
    final path = args[1], count = int.parse(args[2]), layout = args[3];
    final db = await openInMemory();
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,score INTEGER,flag INTEGER,payload TEXT)');
    await db.execute('BEGIN');
    for (var start = 1; start <= count; start += 1000) {
      final rows = <String>[];
      for (var i = start; i < start + 1000 && i <= count; i++) {
        final score = layout == 'ascending'
            ? i
            : layout == 'descending'
                ? count - i
                : layout == 'ties'
                    ? i % 13
                    : (i * 7919) % count;
        rows.add(
            "($i,$score,${i % 7},'payload-${i.toString().padLeft(8, '0')}-abcdefghijklmnop')");
      }
      await db.execute('INSERT INTO items VALUES ${rows.join(',')}');
    }
    await db.execute('COMMIT');
    final image = db.exportImage();
    await File(path).writeAsBytes(image);
    await db.close();
    print(jsonEncode({
      'path': path,
      'rows': count,
      'layout': layout,
      'bytes': image.length,
      'sha256': sha256.convert(image).toString()
    }));
    return;
  }
  final path = args[0],
      k = int.parse(args[1]),
      offset = int.parse(args[2]),
      repeats = int.parse(args[3]),
      mode = args[4];
  final backend = args.length > 5 && args[5] == 'file'
      ? await ReadOnlyFileStorageBackend.open(path)
      : ByteImageStorage(await File(path).readAsBytes());
  final storage = CountingStorage(backend);
  final db = await SqliteDatabase.openReadOnly(storage);
  var comparisons = 0, visits = 0;
  final trace = <String>[];
  db.functions.createCollation('measured', (a, b) {
    comparisons++;
    return a.compareTo(b);
  });
  db.functions.registerScalar('visit', 1, (args) {
    visits++;
    return BigInt.one;
  });
  db.functions.registerScalar('mark', 1, (args) {
    trace.add(args.single.toString());
    return args.single;
  });
  final order =
      mode == 'count' ? 'CAST(score AS TEXT) COLLATE measured,id' : 'score,id';
  final sql = mode == 'point'
      ? 'SELECT payload FROM items WHERE id=?'
      : mode == 'unordered'
          ? 'SELECT id,payload FROM items WHERE flag>=? LIMIT ? OFFSET ?'
          : mode == 'distinct'
              ? 'SELECT DISTINCT score,flag FROM items WHERE flag>=? ORDER BY score,flag LIMIT ? OFFSET ?'
              : 'SELECT ${mode == 'callbacks' ? 'mark(id)' : 'id'},payload FROM items WHERE ${mode == 'count' ? 'visit(id) AND ' : ''}flag>=? ORDER BY $order LIMIT ? OFFSET ?';
  final parameters = mode == 'point' ? <Object?>[k] : <Object?>[0, k, offset];
  final explainClock = Stopwatch()..start();
  final plan = db.explain(sql, parameters);
  explainClock.stop();
  storage.reads = storage.bytes = 0;
  final clock = Stopwatch()..start();
  final hashes = <String>[];
  var resultRows = 0;
  for (var i = 0; i < repeats; i++) {
    final rows = (await db.query(sql, parameters)).rows;
    clock.stop();
    resultRows += rows.length;
    hashes.add(sha256.convert(utf8.encode(rows.toString())).toString());
    clock.start();
  }
  clock.stop();
  print(jsonEncode({
    'sql': sql,
    'k': k,
    'offset': offset,
    'repeats': repeats,
    'mode': mode,
    'backend': args.length > 5 ? args[5] : 'memory',
    'duration_us': clock.elapsedMicroseconds,
    'explain_us': explainClock.elapsedMicroseconds,
    'access': plan.access,
    'reads': storage.reads,
    'read_bytes': storage.bytes,
    'result_rows': resultRows,
    'hashes': hashes,
    'comparisons': comparisons,
    'visits': visits,
    'callback_trace_sha256':
        sha256.convert(utf8.encode(trace.join(','))).toString(),
    'callback_count': trace.length,
    'rss': ProcessInfo.currentRss,
    'peak_rss': ProcessInfo.maxRss,
    'image_bytes': await storage.length()
  }));
  await db.close();
}
