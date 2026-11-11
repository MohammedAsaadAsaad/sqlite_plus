import 'dart:convert';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  final db = await openInMemory();
  const sql =
      'SELECT (?+?)*2 AS n,CASE WHEN ?>0 THEN CAST(? AS INTEGER) ELSE 0 END AS v';
  final prepared = args.single == 'prepared' ? await db.prepare(sql) : null;
  var checksum = BigInt.zero;
  final timer = Stopwatch()..start();
  for (var i = 0; i < 10000; i++) {
    final values = [i, 2, i % 2, i.toString()];
    final result = prepared == null
        ? await db.query(sql, values)
        : await prepared.query(values);
    checksum +=
        (result.rows.single[0] as BigInt) + (result.rows.single[1] as BigInt);
  }
  timer.stop();
  print(jsonEncode({
    'mode': 'syntax',
    'variant': args.single,
    'operations': 10000,
    'duration_us': timer.elapsedMicroseconds,
    'checksum': checksum.toString(),
    'select_parses': prepared?.selectParseCount,
    'expression_parses': prepared?.expressionParseCount
  }));
  await prepared?.close();
  await db.close();
}
