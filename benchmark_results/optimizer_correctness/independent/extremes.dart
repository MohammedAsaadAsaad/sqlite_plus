import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final out = <Map<String, Object?>>[];
  final dir = await Directory.systemTemp.createTemp('optimizer-extreme-');
  for (final encoding in [1, 2, 3]) {
    final db = await MutableSqliteDatabase.create(encoding: encoding);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,rowid TEXT,oid TEXT,_rowid_ TEXT)');
    await db.execute("INSERT INTO t VALUES(1,'z','o','u'),(2,'a','a','a')");
    final ro =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    final path = '${dir.path}/oracle.db';
    await File(path).writeAsBytes(db.exportImage());
    for (final sql in [
      'SELECT min(rowid) AS v FROM t',
      'SELECT max(rowid) AS v FROM t',
      'SELECT min(oid) AS v FROM t',
      'SELECT max(_rowid_) AS v FROM t'
    ]) {
      final n =
          await Process.run('/tmp/sqlite-build/sqlite3', ['-json', path, sql]);
      if (n.exitCode != 0) throw StateError(n.stderr.toString());
      final expected = [
        for (final r in jsonDecode(n.stdout.toString()) as List)
          (r as Map).values.toList()
      ];
      for (final api in ['mutable', 'readOnly']) {
        final result =
            api == 'mutable' ? await db.query(sql) : await ro.query(sql);
        final row = {
          'item': 31,
          'encoding': encoding,
          'api': api,
          'sql': sql,
          'expected': expected,
          'actual': result.rows,
          'pass': jsonEncode(result.rows) == jsonEncode(expected)
        };
        out.add(row);
        if (encoding == 1 && api == 'readOnly') print(jsonEncode(row));
      }
    }
    await ro.close();
    await db.close();
  }
  await File(
          'benchmark_results/optimizer_correctness/independent/repaired_extreme_results.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(out));
  print(jsonEncode({
    'total': out.length,
    'failed': out.where((r) => r['pass'] != true).length
  }));
  await dir.delete(recursive: true);
}
