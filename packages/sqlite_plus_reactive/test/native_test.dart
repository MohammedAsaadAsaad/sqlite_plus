import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart';
import 'package:test/test.dart';

void main() {
  test('reactive filter/order/page snapshots match pinned SQLite', () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    final version =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(version.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final db = await openInMemory();
    await db.execute('PRAGMA recursive_triggers=ON');
    const schema =
        'CREATE TABLE t(a INTEGER,b TEXT,n INTEGER,PRIMARY KEY(a,b))';
    await db.execute(schema);
    final changes = await SqlitePlusChanges.open(database: db);
    await changes.track(table: 't');
    final reactive = ReactiveDatabase(changes);
    final snapshots = <ReactiveSnapshot<Map<String, Object?>>>[];
    const sql =
        'SELECT a,b,n FROM t WHERE n<20 ORDER BY n,a,b LIMIT 2 OFFSET 1';
    final subscription = reactive.watch(sql,
        dependencies: {'t': null},
        keyColumns: ['a', 'b']).listen(snapshots.add);
    final history = <String>[];
    try {
      await reactive.flush();
      for (final write in [
        "INSERT INTO t VALUES(9223372036854775807,'عربي',10),(2,'b',7),(3,'c',15)",
        "UPDATE t SET n=3 WHERE a=3",
        "DELETE FROM t WHERE a=2"
      ]) {
        history.add(write);
        await changes.transaction((tx) => tx.execute(write));
        await reactive.flush();
        final native = await Process.run(
            cli, ['-json', ':memory:', '$schema;${history.join(';')};$sql;']);
        expect(native.exitCode, 0, reason: native.stderr.toString());
        final expected = jsonDecode(native.stdout.toString()) as List;
        expect([
          for (final row in snapshots.last.items)
            {
              for (final e in row.entries)
                e.key: e.value is BigInt ? (e.value as BigInt).toInt() : e.value
            }
        ], expected);
      }
    } finally {
      await subscription.cancel();
      await reactive.close();
      await db.close();
    }
  });
}
