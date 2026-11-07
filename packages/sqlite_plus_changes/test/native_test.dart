import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  test('events match pinned SQLite and persisted images cross-open', () async {
    final version =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(version.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final folder = await Directory.systemTemp.createTemp('changes-native-');
    addTearDown(() => folder.delete(recursive: true));
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY,label TEXT,n INTEGER)');
    final feed = await SqlitePlusChanges.open(database: db);
    await feed.track(table: 'docs');
    final file = File('${folder.path}/seed.db');
    await file.writeAsBytes(db.exportImage());
    const statements = [
      "INSERT INTO docs VALUES(9223372036854775807,'حليب',10)",
      "UPDATE docs SET label='tea',n=11 WHERE id=9223372036854775807",
      'UPDATE docs SET n=n WHERE id=9223372036854775807',
      'DELETE FROM docs WHERE id=9223372036854775807'
    ];
    const select =
        'SELECT kind,old_key,new_key,columns_json FROM _spc_events ORDER BY id';
    final native = await Process.run(cli, [
      '-json',
      file.path,
      "PRAGMA recursive_triggers=ON; BEGIN; UPDATE _spc_state SET active_batch=1 WHERE id=1; ${statements.join(';')}; $select; ROLLBACK;"
    ]);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    final expected = jsonDecode(native.stdout.toString()) as List;
    await feed.transaction((tx) async {
      for (final sql in statements) {
        await tx.execute(sql);
      }
    });
    final actual = await db.query(select);
    expect([
      for (final row in actual.rows)
        {
          for (var i = 0; i < actual.columns.length; i++)
            actual.columns[i]: row[i]
        }
    ], expected);
    await file.writeAsBytes(db.exportImage());
    final check = await Process.run(cli, [
      file.path,
      'PRAGMA integrity_check; SELECT event_count FROM _spc_batches WHERE id>0;'
    ]);
    expect(check.exitCode, 0, reason: check.stderr.toString());
    expect(check.stdout.toString().trim(), 'ok\n3');
    final guard = await Process.run(
        cli, [file.path, "INSERT INTO docs VALUES(1,'outside',1);"]);
    expect(guard.exitCode, isNot(0));
    expect(guard.stderr.toString(), contains('Tracked writes require'));
    final opened =
        await MutableSqliteDatabase.fromImage(await file.readAsBytes());
    addTearDown(opened.close);
    final again = await SqlitePlusChanges.open(database: opened);
    final batch = await (await again.consumer(name: 'native')).read();
    expect(batch.events.length, 3);
    expect(batch.events.first.key['id'], (BigInt.one << 63) - BigInt.one);
    await (await again.consumer(name: 'native')).acknowledge(batch.checkpoint);
    await again.pruneAcknowledged();
    await file.writeAsBytes(opened.exportImage());
    final pruned = await Process.run(cli, [
      file.path,
      'PRAGMA integrity_check; SELECT count(*) FROM _spc_events; SELECT count(*) FROM _spc_batches WHERE id>0;'
    ]);
    expect(pruned.exitCode, 0, reason: pruned.stderr.toString());
    expect(pruned.stdout.toString().trim(), 'ok\n0\n0');
  }, skip: !File(cli).existsSync() ? 'Pinned SQLite CLI unavailable' : false);
}
