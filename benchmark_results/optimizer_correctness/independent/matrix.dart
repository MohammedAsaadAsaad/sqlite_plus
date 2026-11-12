import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';

Object? normalized(Object? x) {
  if (x is BigInt) return x.toInt();
  if (x is Uint8List) return x.toList();
  if (x is List) return x.map(normalized).toList();
  return x;
}

Future<void> main(List<String> args) async {
  final label = args.isEmpty ? 'current' : args.first;
  final cases = <Map<String, Object?>>[];
  final scenarios = <Map<String, Object>>[
    {
      'name': 'cover/order/range',
      'items': [
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        14,
        17,
        19,
        20,
        30,
        31,
        32,
        33,
        34,
        36,
        38,
        39,
        40
      ],
      'setup': [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,b INT,c TEXT)',
        "INSERT INTO t VALUES(1,1,30,'A'),(2,2,10,'b'),(3,3,20,'a'),(4,1,40,'B'),(5,NULL,50,NULL),(6,2,60,'z')",
        'CREATE INDEX ia ON t(a)',
        'CREATE INDEX iab ON t(a,b)',
        'CREATE INDEX ib ON t(b DESC)',
      ],
      'queries': [
        'SELECT a FROM t WHERE a>0 ORDER BY b',
        'SELECT a FROM t INDEXED BY ia WHERE a>0 GROUP BY b ORDER BY b',
        'SELECT a FROM t WHERE a>0 GROUP BY b HAVING b>15 ORDER BY b',
        'SELECT a FROM t WHERE a>0 ORDER BY b LIMIT 2 OFFSET 1',
        'SELECT a,b FROM t WHERE a=1 ORDER BY b,id',
        'SELECT a,b FROM t WHERE a=1 ORDER BY b DESC,id',
        'SELECT a FROM t WHERE a BETWEEN 1 AND 2 ORDER BY a',
        'SELECT a FROM t WHERE a NOT BETWEEN 1 AND 2 ORDER BY a',
        'SELECT a,b FROM t WHERE a IN (3,1,1,NULL) ORDER BY a,b',
        'SELECT a,b FROM t WHERE a=3 OR a=1 ORDER BY a,b',
        'SELECT id FROM t WHERE a IN (2,1) AND b>15 ORDER BY id',
        'SELECT DISTINCT a FROM t ORDER BY a NULLS LAST',
        'SELECT DISTINCT a FROM t ORDER BY a DESC NULLS FIRST',
        'SELECT a,count(*) AS n,sum(b) AS s FROM t GROUP BY a ORDER BY a',
        'SELECT min(id),max(id),count(*),sum(b),avg(b),total(b) FROM t',
        'SELECT count(*) FROM t WHERE a>2 AND a<2',
        'SELECT id FROM t WHERE (a>2 AND a<2) OR id=2 ORDER BY id',
        'SELECT 1+2 AS x,8/2 AS y,typeof(1+2) AS z',
        'SELECT id FROM t NOT INDEXED LIMIT 2 OFFSET 1',
        'SELECT id FROM t ORDER BY id DESC LIMIT 2 OFFSET 1',
        'SELECT a FROM t NOT INDEXED WHERE a>0 ORDER BY b',
      ]
    },
    {
      'name': 'shadow-rowid',
      'items': [11],
      'setup': [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,rowid TEXT,oid TEXT,_rowid_ TEXT)',
        "INSERT INTO t VALUES(1,7,'actual','o','u')",
        'CREATE INDEX ia ON t(a)'
      ],
      'queries': [
        'SELECT rowid FROM t WHERE a=7',
        'SELECT oid FROM t WHERE a=7',
        'SELECT _rowid_ FROM t WHERE a=7',
        'SELECT a FROM t WHERE a=7 AND rowid IS NOT NULL',
        'SELECT rowid FROM t NOT INDEXED WHERE a=7'
      ]
    },
    {
      'name': 'join-star',
      'items': [22, 23, 24, 25, 38],
      'setup': [
        'CREATE TABLE t(a INT)',
        'CREATE TABLE s(b INT)',
        'INSERT INTO t VALUES(2),(1)',
        'INSERT INTO s VALUES(9)',
        'ANALYZE'
      ],
      'queries': [
        'SELECT * FROM t CROSS JOIN s ORDER BY t.a',
        'SELECT t.a,s.b FROM t CROSS JOIN s ORDER BY t.a'
      ]
    },
    {
      'name': 'scalar-cache',
      'items': [26, 27, 28, 29, 35, 37],
      'setup': [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,b INT)',
        'INSERT INTO t VALUES(1,10,30),(2,20,10),(3,30,20)'
      ],
      'queries': [
        'SELECT (SELECT a FROM t LIMIT 1) AS x,(SELECT a FROM t LIMIT 1 OFFSET 1) AS y',
        'SELECT (SELECT count(*) FROM t LIMIT 0) AS x,(SELECT count(*) FROM t LIMIT 1) AS y',
        'SELECT (SELECT sum(a%20) AS n FROM t) AS x,(SELECT sum(DISTINCT a%20) AS n FROM t) AS y',
        'SELECT (SELECT a IN (10) AS v FROM t LIMIT 1) AS x,(SELECT a NOT IN (10) AS v FROM t LIMIT 1) AS y',
        'SELECT (SELECT a FROM t LIMIT 1 OFFSET 1) AS x,(SELECT a FROM t LIMIT 1) AS y',
        "SELECT (SELECT CAST(a AS TEXT) AS v FROM t LIMIT 1) AS x,(SELECT CAST(a AS INTEGER) AS v FROM t LIMIT 1) AS y",
        'SELECT (SELECT a FROM t ORDER BY id LIMIT 1) AS x,(SELECT a FROM t ORDER BY id LIMIT 1 OFFSET 2) AS y',
        'SELECT id,(SELECT count(*) FROM t AS inner_t WHERE inner_t.a<t.a) AS n FROM t ORDER BY id',
        'SELECT EXISTS(SELECT 1 FROM t WHERE a=20) AS x,EXISTS(SELECT 1 FROM t WHERE a=99) AS y',
        'WITH x AS MATERIALIZED(SELECT a,b FROM t LIMIT 2) SELECT a FROM x WHERE b>15 ORDER BY a',
        'SELECT a FROM (SELECT a,b FROM t LIMIT 2) AS x WHERE b>15 ORDER BY a',
        'SELECT a FROM (SELECT a,b FROM t ORDER BY b LIMIT 2) AS x ORDER BY a'
      ]
    },
    {
      'name': 'text-affinity',
      'items': [13, 14, 21, 34],
      'setup': [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT COLLATE BINARY)',
        "INSERT INTO t VALUES(1,'15'),(2,'3'),(3,'A'),(4,'a'),(5,'2')",
        'CREATE INDEX ia ON t(a)',
        'CREATE INDEX partial ON t(a) WHERE a>2'
      ],
      'queries': [
        'SELECT a FROM t WHERE a>10 AND a<2 ORDER BY a',
        'SELECT a FROM t WHERE a>10 ORDER BY a',
        "SELECT a FROM t WHERE a COLLATE NOCASE='a' OR a COLLATE NOCASE='b' ORDER BY id",
        "SELECT a FROM t WHERE a='a' COLLATE NOCASE OR a='b' COLLATE NOCASE ORDER BY id",
        "SELECT a FROM t WHERE a COLLATE NOCASE IN ('a','b') ORDER BY id",
        "SELECT a FROM t WHERE a='a' OR a='b' ORDER BY id"
      ]
    },
    {
      'name': 'text-partial-only',
      'items': [13],
      'setup': [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT)',
        "INSERT INTO t VALUES(1,'15'),(2,'3'),(3,'2')",
        'CREATE INDEX partial ON t(a) WHERE a>2'
      ],
      'queries': [
        'SELECT a FROM t WHERE a>10 ORDER BY a',
        'SELECT a FROM t NOT INDEXED WHERE a>10 ORDER BY a'
      ]
    },
    {
      'name': 'without-rowid',
      'items': [6, 7, 9, 12, 15],
      'setup': [
        'CREATE TABLE t(id INT PRIMARY KEY,a INT,b TEXT) WITHOUT ROWID',
        "INSERT INTO t VALUES(1,3,'c'),(2,1,'a'),(3,2,'b'),(4,1,'d')",
        'CREATE INDEX ia ON t(a)'
      ],
      'queries': [
        'SELECT id,a FROM t WHERE a=1 ORDER BY id',
        'SELECT id,a FROM t WHERE a BETWEEN 1 AND 2 ORDER BY a,id',
        'SELECT id,a FROM t ORDER BY id DESC LIMIT 2',
        'SELECT id,a FROM t ORDER BY a,id',
        'SELECT id,a FROM t NOT INDEXED ORDER BY id'
      ]
    },
  ];
  final temp = await Directory.systemTemp.createTemp('optimizer-independent-');
  try {
    for (final encoding in [1, 2, 3]) {
      for (final scenario in scenarios) {
        final db = await MutableSqliteDatabase.create(encoding: encoding);
        for (final setup in scenario['setup'] as List<String>) {
          await db.execute(setup);
        }
        final image = db.exportImage();
        final path = '${temp.path}/oracle.db';
        await File(path).writeAsBytes(image);
        final ro = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
        for (final sql in scenario['queries'] as List<String>) {
          stderr.writeln('CHECK encoding=$encoding ${scenario['name']} $sql');
          // Pinned SQLite's indexed RHS-COLLATE OR loses a row; compare its scan.
          final referenceSql = sql ==
                  "SELECT a FROM t WHERE a='a' COLLATE NOCASE OR a='b' COLLATE NOCASE ORDER BY id"
              ? sql.replaceFirst('FROM t WHERE', 'FROM t NOT INDEXED WHERE')
              : sql;
          final native = await Process.run(
              '/tmp/sqlite-build/sqlite3', ['-json', path, referenceSql]);
          if (native.exitCode != 0) {
            throw StateError('native: $sql ${native.stderr}');
          }
          final json = native.stdout.toString().trim();
          final maps = json.isEmpty ? <dynamic>[] : jsonDecode(json) as List;
          final expected = [
            for (final row in maps) (row as Map).values.toList()
          ];
          for (final api in ['mutable', 'readOnly']) {
            final item = <String, Object?>{
              'scenario': scenario['name'],
              'items': scenario['items'],
              'encoding': encoding,
              'api': api,
              'sql': sql,
              'expected': expected
            };
            try {
              final result =
                  api == 'mutable' ? await db.query(sql) : await ro.query(sql);
              final actual = normalized(result.rows);
              item['actual'] = actual;
              item['pass'] = jsonEncode(actual) == jsonEncode(expected);
              if (sql.startsWith('SELECT *') && maps.isNotEmpty) {
                item['expectedColumns'] = (maps.first as Map).keys.toList();
                item['actualColumns'] = result.columns;
                item['pass'] = item['pass'] == true &&
                    jsonEncode(result.columns) ==
                        jsonEncode((maps.first as Map).keys.toList());
              }
            } catch (e, st) {
              item['pass'] = false;
              item['error'] = e.toString();
              item['stack'] = st.toString().split('\n').take(6).join('\n');
            }
            cases.add(item);
            await File(
                    'benchmark_results/optimizer_correctness/independent/${label}_cases.jsonl')
                .writeAsString('${jsonEncode(item)}\n', mode: FileMode.append);
          }
        }
        await ro.close();
        await db.close();
      }
    }
  } finally {
    await temp.delete(recursive: true);
  }
  final failures = cases.where((r) => r['pass'] != true).toList();
  final report = {
    'total': cases.length,
    'passed': cases.length - failures.length,
    'failed': failures.length,
    'distinctFailingSQL': failures.map((r) => r['sql']).toSet().length,
    'cases': cases
  };
  await File(
          'benchmark_results/optimizer_correctness/independent/${label}_results.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode({
    'total': cases.length,
    'passed': cases.length - failures.length,
    'failed': failures.length,
    'distinctFailingSQL': failures.map((r) => r['sql']).toSet().length
  }));
  for (final f
      in failures.where((f) => f['encoding'] == 1 && f['api'] == 'readOnly')) {
    print(jsonEncode(f));
  }
}
