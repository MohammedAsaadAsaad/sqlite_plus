import 'package:sqlite_plus/sqlite_plus.dart';

/// One fresh-process sample for a reversed full scan. Prints microseconds
/// and a checksum. The same driver is compiled in the baseline and candidate.
Future<void> main(List<String> args) async {
  final mode = args[0];
  final rows = int.parse(args[1]);
  final db = await MutableSqliteDatabase.create();
  await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
  if (mode == 'adesc') await db.execute('CREATE INDEX ia ON t(a)');
  final inserted = StringBuffer('INSERT INTO t(id,a,b) VALUES ');
  for (var i = 0; i < rows; i++) {
    if (i > 0) inserted.write(',');
    inserted.write("(${i + 1},${rows - i},'v${i % 97}')");
  }
  await db.execute(inserted.toString());
  final watch = Stopwatch()..start();
  final sql = switch (mode) {
    'iddesc' => 'SELECT id FROM t ORDER BY id DESC',
    'adesc' => 'SELECT a FROM t ORDER BY a DESC',
    _ => throw ArgumentError(mode),
  };
  final result = await db.query(sql);
  final first = (result.rows.first.single as BigInt).toInt();
  final last = (result.rows.last.single as BigInt).toInt();
  watch.stop();
  await db.close();
  print('${watch.elapsedMicroseconds} ${result.rows.length ^ first ^ last}');
}
