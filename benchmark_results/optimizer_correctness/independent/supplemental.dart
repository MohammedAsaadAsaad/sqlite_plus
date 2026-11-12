import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Object? norm(Object? x) => x is BigInt
    ? x.toInt()
    : x is List
        ? x.map(norm).toList()
        : x;
Future<void> main(List<String> args) async {
  final label = args.isEmpty ? 'current' : args.first;
  final db = await MutableSqliteDatabase.create();
  const setup = [
    'CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT,b INT)',
    "INSERT INTO t VALUES(1,'A',30),(2,'B',10),(3,'a',20),(4,'b',40)"
  ];
  for (final s in setup) {
    await db.execute(s);
  }
  final ro =
      await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
  final dir = await Directory.systemTemp.createTemp('optimizer-supplement-');
  final path = '${dir.path}/test.db';
  await File(path).writeAsBytes(db.exportImage());
  const queries = <int, List<String>>{
    21: [
      'SELECT 1 OR abs(-9223372036854775808) AS v',
      'SELECT 0 AND abs(-9223372036854775808) AS v',
      'SELECT NULL OR abs(-9223372036854775808) AS v'
    ],
    33: [
      "SELECT v FROM (SELECT CAST(1 AS INTEGER) AS v) WHERE v='1'",
      "SELECT v FROM (SELECT CAST(1 AS TEXT) AS v) WHERE v=1",
      "SELECT v FROM (SELECT 'A' COLLATE NOCASE AS v) WHERE v='a'",
      "WITH x AS MATERIALIZED(SELECT CAST(1 AS INTEGER) AS v) SELECT v FROM x WHERE v='1'"
    ],
    35: [
      'SELECT x.a,(SELECT x.b) AS v FROM (SELECT a,b FROM t LIMIT 2 OFFSET 0) AS x ORDER BY x.a',
      'SELECT x.a,(SELECT x.b+1) AS v FROM (SELECT a,b FROM t LIMIT 2 OFFSET 0) AS x ORDER BY x.a'
    ],
    30: [
      "SELECT DISTINCT a COLLATE NOCASE AS v FROM t ORDER BY a COLLATE BINARY",
      "SELECT DISTINCT a COLLATE NOCASE AS v FROM t ORDER BY v COLLATE BINARY",
      'SELECT a,count(*) AS n FROM t GROUP BY a COLLATE NOCASE ORDER BY a COLLATE NOCASE'
    ],
    37: [
      'SELECT (SELECT 1 AS v) AS x,(SELECT \'1\' AS v) AS y',
      'SELECT (SELECT a FROM t ORDER BY a NULLS FIRST LIMIT 1) AS x,(SELECT a FROM t ORDER BY a NULLS LAST LIMIT 1) AS y'
    ]
  };
  final all = <Map<String, Object?>>[];
  for (final entry in queries.entries) {
    for (final sql in entry.value) {
      stderr.writeln('CHECK $label item=${entry.key} $sql');
      final native =
          await Process.run('/tmp/sqlite-build/sqlite3', ['-json', path, sql]);
      final text = native.stdout.toString().trim();
      final expected = native.exitCode == 0
          ? (text.isEmpty
              ? []
              : [
                  for (final r in jsonDecode(text) as List)
                    (r as Map).values.toList()
                ])
          : null;
      for (final api in ['mutable', 'readOnly']) {
        final r = <String, Object?>{
          'item': entry.key,
          'sql': sql,
          'api': api,
          'nativeError': native.exitCode != 0,
          'expected': expected
        };
        if (native.exitCode != 0)
          r['nativeErrorText'] = native.stderr.toString();
        try {
          final result =
              api == 'mutable' ? await db.query(sql) : await ro.query(sql);
          r['actual'] = norm(result.rows);
          r['pass'] = native.exitCode == 0 &&
              jsonEncode(r['actual']) == jsonEncode(expected);
        } catch (e) {
          r['error'] = e.toString();
          r['pass'] = native.exitCode != 0;
        }
        all.add(r);
      }
    }
  }
  final bad = all.where((r) => r['pass'] != true).toList();
  await File(
          'benchmark_results/optimizer_correctness/independent/${label}_supplemental.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert({
    'total': all.length,
    'passed': all.length - bad.length,
    'failed': bad.length,
    'cases': all
  }));
  print(jsonEncode({
    'total': all.length,
    'passed': all.length - bad.length,
    'failed': bad.length
  }));
  for (final r in bad.where((r) => r['api'] == 'readOnly')) {
    print(jsonEncode(r));
  }
  await ro.close();
  await db.close();
  await dir.delete(recursive: true);
}
