import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

final class JoinCountingStorage implements StorageBackend {
  JoinCountingStorage(this.inner);
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
  if (args.first == 'seed') {
    final path = args[1], count = int.parse(args[2]);
    final dense = args.length > 3 && args[3] == 'dense';
    final db = await MutableSqliteDatabase.create();
    await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY,k INT)');
    await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY,k INT,v TEXT)');
    await db.execute('CREATE INDEX bk ON b(k)');
    await db.execute(
        'INSERT INTO a VALUES(1,1),(2,$count),(3,1),(4,NULL),(5,${count + 1})');
    for (var start = 1; start <= count; start += 500) {
      await db.execute('INSERT INTO b VALUES ${[
        for (var i = start; i < start + 500 && i <= count; i++)
          "($i,${dense ? 1 : i},'${'x' * 100}')"
      ].join(',')}');
    }
    await db.execute('ANALYZE');
    await File(path).writeAsBytes(db.exportImage());
    await db.close();
    return;
  }
  final image = await File(args[0]).readAsBytes();
  final mode = args[1];
  final storage = JoinCountingStorage(ByteImageStorage(image));
  final db = await SqliteDatabase.openReadOnly(storage);
  final trace = <String>[];
  db.functions.registerScalar('mark', 1, (args) {
    trace.add(args.single.toString());
    return args.single;
  });
  const base =
      'SELECT a.id AS aid,b.id AS bid,b.v FROM a INNER JOIN b ON a.k=b.k ORDER BY a.id,b.id';
  final sql = mode == 'scan'
      ? base.replaceFirst('JOIN b ON', 'JOIN b NOT INDEXED ON')
      : mode == 'empty'
          ? base.replaceFirst('a.k=b.k', 'a.k=b.k AND b.id<0')
          : mode == 'callbacks'
              ? base.replaceFirst('a.id AS aid', 'mark(a.id) AS aid')
              : base;
  final planning = Stopwatch()..start();
  final plan = db.describeQueryPlan(sql);
  planning.stop();
  storage.reads = storage.bytes = 0;
  final clock = Stopwatch()..start();
  final result = await db.query(sql);
  clock.stop();
  print(jsonEncode({
    'mode': mode,
    'plan': plan,
    'explain_us': planning.elapsedMicroseconds,
    'callback_count': trace.length,
    'callback_trace_sha256':
        sha256.convert(utf8.encode(trace.join(','))).toString(),
    'duration_us': clock.elapsedMicroseconds,
    'hash': sha256.convert(utf8.encode(result.rows.toString())).toString(),
    'rows': result.rows.length,
    'columns': result.columns,
    'reads': storage.reads,
    'read_bytes': storage.bytes,
    'peak_rss': ProcessInfo.maxRss,
    'image_bytes': image.length
  }));
  await db.close();
}
