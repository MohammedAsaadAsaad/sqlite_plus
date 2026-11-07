import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';
import 'support/replica.dart';

const cli = '/tmp/sqlite-build/sqlite3';
void main() {
  setUpAll(() async {
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
    expect(pin.exitCode, 0);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
  });

  test(
      'atomic incoming SQL matches SQLite and origin metadata survives cross-open',
      () async {
    final server = MemorySyncServer();
    final c = await Replica.open(server);
    addTearDown(c.db.close);
    final dir = await Directory.systemTemp.createTemp('sync-native-');
    addTearDown(() => dir.delete(recursive: true));
    final seed = File('${dir.path}/seed.db');
    await seed.writeAsBytes(c.db.exportImage());
    final feed = (await c.changes.head()).feedId;
    final key = jsonEncode(SyncCodec.fields({'id': 'p'})).replaceAll("'", "''");
    final sql = """
PRAGMA recursive_triggers=ON;
BEGIN;
UPDATE _spc_state SET active_batch=1 WHERE id=1;
INSERT INTO products VALUES('p','milk',10);
INSERT INTO _spsync_rows(table_id,key_json,version,tombstone,discard_through,force_full) VALUES(1,'$key','1',0,0,0);
INSERT INTO _spsync_remote(feed,batch_id) VALUES('$feed',1);
UPDATE _spsync_state SET cursor='1' WHERE id=1;
INSERT INTO _spc_batches VALUES(1,1);
UPDATE _spc_state SET next_batch=2,active_batch=NULL WHERE id=1;
COMMIT;
""";
    final native = await Process.run(cli, [seed.path, sql]);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    await server.push(SyncOperation(id: 'seed', scope: 'shop', mutations: [
      SyncMutation(
          table: 'products',
          key: {'id': 'p'},
          baseVersion: null,
          values: {'id': 'p', 'name': 'milk', 'price': 10})
    ]));
    await c.sync.runOnce();
    for (final query in [
      'SELECT * FROM products',
      'SELECT format,scope,replica,feed,initial_batch,next_operation,cursor FROM _spsync_state',
      'SELECT * FROM _spsync_rows',
      'SELECT * FROM _spsync_remote',
      'SELECT * FROM _spc_events',
      'SELECT * FROM _spc_batches',
      'SELECT * FROM _spc_state',
    ]) {
      final expected = await Process.run(cli, ['-json', seed.path, query]);
      expect(expected.exitCode, 0, reason: expected.stderr.toString());
      final actual = await c.db.query(query);
      final rows = [
        for (final row in actual.rows)
          {
            for (var i = 0; i < actual.columns.length; i++)
              actual.columns[i]:
                  row[i] is BigInt ? (row[i] as BigInt).toInt() : row[i]
          }
      ];
      expect(rows, jsonDecode(expected.stdout.toString()), reason: query);
    }
    final file = File('${dir.path}/dart.db');
    await file.writeAsBytes(c.db.exportImage());
    final check = await Process.run(cli, [file.path, 'PRAGMA integrity_check']);
    expect(check.stdout.toString().trim(), 'ok');
    final reopened = await Replica.open(server, image: c.db.exportImage());
    addTearDown(reopened.db.close);
    await reopened.sync.runOnce();
    expect(server.applications, 1);
    final observer = await reopened.changes.consumer(name: 'native-observer');
    expect((await observer.read()).events.length, 1);
  });

  test('outbox/conflict/resolution and deletion images pass native integrity',
      () async {
    final server = MemorySyncServer();
    final a = await Replica.open(server);
    final b = await Replica.open(server);
    addTearDown(a.db.close);
    addTearDown(b.db.close);
    final dir = await Directory.systemTemp.createTemp('sync-phases-');
    addTearDown(() => dir.delete(recursive: true));
    Future<void> check(MutableSqliteDatabase db) async {
      final file = File('${dir.path}/image.db');
      await file.writeAsBytes(db.exportImage());
      final native =
          await Process.run(cli, [file.path, 'PRAGMA integrity_check']);
      expect(native.exitCode, 0);
      expect(native.stdout.toString().trim(), 'ok');
      final reopened =
          await MutableSqliteDatabase.fromImage(await file.readAsBytes());
      expect(
          (await reopened.query('PRAGMA integrity_check')).rows.single.single,
          'ok');
      await reopened.close();
    }

    await a.write("INSERT INTO products VALUES('p','remote',10)");
    await a.sync.runOnce();
    await b.sync.runOnce();
    await a.write("UPDATE products SET price=12 WHERE id='p'");
    await a.sync.runOnce();
    await b.write("UPDATE products SET price=99 WHERE id='p'");
    await b.sync.runOnce();
    await check(b.db);
    await b.sync.resolveConflict(
        (await b.sync.conflicts()).single.id, SyncResolution.keepLocal);
    await check(b.db);
    await b.sync.runOnce();
    await check(b.db);
    await a.sync.runOnce();
    await a.write("DELETE FROM products WHERE id='p'");
    await a.sync.runOnce();
    await b.sync.runOnce();
    await b.sync.runOnce();
    await check(b.db);
  });
}
