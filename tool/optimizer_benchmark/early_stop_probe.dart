import 'package:sqlite_plus/sqlite_plus.dart';

/// One fresh-process sample for a bounded ordered read.
/// Prints microseconds and a checksum.
Future<void> main(List<String> args) async {
  final mode = args[0];
  final rows = int.parse(args[1]);
  final db = await MutableSqliteDatabase.create();
  await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
  final inserted = StringBuffer('INSERT INTO t(id,a,b) VALUES ');
  for (var i = 0; i < rows; i++) {
    if (i > 0) inserted.write(',');
    inserted.write("(${i + 1},${i % 17},'v${i % 97}')");
  }
  await db.execute(inserted.toString());
  final watch = Stopwatch()..start();
  final sql = switch (mode) {
    'ordered' => 'SELECT id FROM t ORDER BY id DESC LIMIT 1',
    'filtered' => "SELECT id FROM t WHERE b = 'v0' ORDER BY id LIMIT 1",
    _ => throw ArgumentError(mode),
  };
  final result = await db.query(sql);
  final checksum = result.rows.length ^
      (result.rows.single.single as BigInt).toInt();
  watch.stop();
  await db.close();
  print('${watch.elapsedMicroseconds} $checksum');
}
