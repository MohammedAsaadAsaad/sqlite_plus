import 'package:sqlite_plus/sqlite_plus.dart';

/// One fresh-process sample for item 6. Prints microseconds and a checksum.
Future<void> main(List<String> args) async {
  final mode = args[0];
  final rows = int.parse(args[1]);
  final db = await MutableSqliteDatabase.create();
  await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
  if (mode == 'index' || mode == 'sort' || mode == 'wide') {
    await db.execute('CREATE INDEX ia ON t(a)');
  }
  final inserted = StringBuffer('INSERT INTO t(id,a,b) VALUES ');
  for (var i = 0; i < rows; i++) {
    if (i > 0) inserted.write(',');
    inserted.write("(${i + 1},${rows - i},'v${i % 97}')");
  }
  await db.execute(inserted.toString());
  final watch = Stopwatch()..start();
  var checksum = 0;
  switch (mode) {
    case 'index':
      final result = await db.query('SELECT a FROM t ORDER BY a');
      checksum =
          result.rows.length ^ (result.rows.first.single as BigInt).toInt();
    case 'wide':
      final result = await db.query('SELECT a, b FROM t ORDER BY a, b');
      checksum = result.rows.length;
    case 'rowid':
      final result = await db.query('SELECT id FROM t ORDER BY id');
      checksum = (result.rows.first.single as BigInt).toInt() ^
          (result.rows.last.single as BigInt).toInt();
    case 'sort':
      final result = await db.query('SELECT b FROM t ORDER BY b');
      checksum = result.rows.length ^ result.rows.first.single.hashCode;
    case 'update':
      for (var i = 1; i <= 200; i++) {
        await db.execute('UPDATE t SET b=? WHERE id=?', ['x$i', i]);
      }
      checksum = 200;
    default:
      throw ArgumentError(mode);
  }
  watch.stop();
  await db.close();
  print('${watch.elapsedMicroseconds} $checksum');
}
