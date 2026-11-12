import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  final label = args.isEmpty ? 'current' : args.first;
  final db = await MutableSqliteDatabase.create();
  await db.execute('CREATE TABLE flags(a INT)');
  await db.execute('INSERT INTO flags VALUES(1),(0),(NULL)');
  final calls = <String>[];
  db.functions.registerScalar('probe', 0, (_) {
    calls.add('probe');
    return 7;
  });
  final ro = await SqliteDatabase.openReadOnly(
      ByteImageStorage(db.exportImage()),
      functions: db.functions);
  final cases = <Map<String, Object?>>[];
  for (final op in ['OR', 'AND']) {
    final sql = 'SELECT a $op probe() AS v FROM flags ORDER BY rowid';
    final python = await Process.run('python3', [
      '-c',
      "import sqlite3,json,sys;c=sqlite3.connect(':memory:');calls=[];c.create_function('probe',0,lambda:(calls.append('probe') or 7));c.executescript('CREATE TABLE flags(a INT);INSERT INTO flags VALUES(1),(0),(NULL)');rows=c.execute(sys.argv[1]).fetchall();print(json.dumps({'rows':rows,'calls':calls,'source_id':c.execute('select sqlite_source_id()').fetchone()[0]}))",
      sql
    ]);
    if (python.exitCode != 0) throw StateError(python.stderr.toString());
    final expected = jsonDecode(python.stdout.toString()) as Map;
    if (expected['source_id'] !=
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9')
      throw StateError('Wrong reference');
    for (final api in ['mutable', 'readOnly']) {
      calls.clear();
      final r = api == 'mutable' ? await db.query(sql) : await ro.query(sql);
      final rows = [
        for (final row in r.rows)
          [for (final v in row) v is BigInt ? v.toInt() : v]
      ];
      final data = {
        'item': 21,
        'sql': sql,
        'api': api,
        'expectedRows': expected['rows'],
        'actualRows': rows,
        'expectedCalls': expected['calls'],
        'actualCalls': List.of(calls),
        'pass': jsonEncode(rows) == jsonEncode(expected['rows']) &&
            jsonEncode(calls) == jsonEncode(expected['calls'])
      };
      cases.add(data);
      print(jsonEncode(data));
    }
  }
  await File(
          'benchmark_results/optimizer_correctness/independent/${label}_callbacks.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(cases));
  await ro.close();
  await db.close();
}
