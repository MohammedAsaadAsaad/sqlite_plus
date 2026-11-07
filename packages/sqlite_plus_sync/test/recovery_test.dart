import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';
import 'support/fault_storage.dart';
import 'support/replica.dart';

final class _Offline implements Exception {}

Future<MutableSqliteDatabase> _open(
        FaultStorage data, FaultStorage log) async =>
    MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(data, log));

void main() {
  for (final phase in ['enqueue', 'confirm', 'pull', 'resolve']) {
    for (final mode in ['delete', 'persist']) {
      for (final immediate in [false, true]) {
        test('$phase recovery $mode immediate=$immediate', () async {
          final server = MemorySyncServer();
          final hooks = Hooks(server);
          final seed = await Replica.open(hooks, id: 'recovery');
          if (phase != 'pull') {
            await seed.write("INSERT INTO products VALUES('p','local',10)");
          }
          if (phase == 'confirm') {
            hooks.onPush = (op) async => throw _Offline();
            await expectLater(seed.sync.runOnce(), throwsA(isA<_Offline>()));
            hooks.onPush = null;
          }
          if (phase == 'pull' || phase == 'resolve') {
            await server.push(
                SyncOperation(id: 'server-seed', scope: 'shop', mutations: [
              SyncMutation(
                  table: 'products',
                  key: {'id': 'p'},
                  baseVersion: null,
                  values: {'id': 'p', 'name': 'remote', 'price': 20})
            ]));
          }
          if (phase == 'resolve') {
            expect((await seed.sync.runOnce()).conflicts, 1);
          }
          final image = seed.db.exportImage();
          await seed.db.close();
          Future<(MutableSqliteDatabase, SqlitePlusSync)> setup(
              Faults faults, FaultStorage data, FaultStorage log) async {
            final db = await _open(data, log);
            await db.execute('PRAGMA journal_mode=$mode');
            await db.execute('PRAGMA recursive_triggers=ON');
            final changes = await SqlitePlusChanges.open(database: db);
            final sync = await SqlitePlusSync.open(
                changes: changes, transport: hooks, scope: 'shop');
            faults.operations = 0;
            return (db, sync);
          }

          Future<void> action(SqlitePlusSync sync) async {
            if (phase == 'resolve') {
              await sync.resolveConflict((await sync.conflicts()).single.id,
                  SyncResolution.acceptRemote);
            } else {
              hooks.onPush =
                  phase == 'enqueue' ? (op) async => throw _Offline() : null;
              try {
                await sync.runOnce();
              } on _Offline {
                if (phase != 'enqueue') rethrow;
              }
            }
          }

          final baseline = Faults()..immediatePersistence = immediate;
          final data = FaultStorage(image, baseline),
              log = FaultStorage(Uint8List(0), baseline);
          final (baseDb, baseSync) = await setup(baseline, data, log);
          await action(baseSync);
          final count = baseline.operations;
          expect(count, greaterThan(0));
          await baseDb.close();
          print('$phase $mode immediate=$immediate fault points: $count');
          for (var point = 1; point <= count; point++) {
            final faults = Faults()..immediatePersistence = immediate;
            final data = FaultStorage(image, faults),
                log = FaultStorage(Uint8List(0), faults);
            final (_, sync) = await setup(faults, data, log);
            faults.failAfter = point;
            await expectLater(action(sync), throwsA(isA<PowerLoss>()));
            data.losePower();
            log.losePower();
            faults.failAfter = null;
            hooks.onPush = null;
            final db = await _open(data, log);
            await db.execute('PRAGMA recursive_triggers=ON');
            final changes = await SqlitePlusChanges.open(database: db);
            final restored = await SqlitePlusSync.open(
                changes: changes, transport: hooks, scope: 'shop');
            final outbox =
                (await db.query('SELECT id FROM _spsync_outbox WHERE id>0'))
                    .rows;
            final consumer = (await db.query(
                    "SELECT acked_batch FROM _spc_consumers NOT INDEXED WHERE name='_spsync_outbound'"))
                .rows
                .single
                .single;
            if (phase == 'enqueue') {
              expect(outbox.length, anyOf(0, 1));
              expect(consumer, outbox.isEmpty ? BigInt.zero : BigInt.one);
            }
            if (phase == 'pull') {
              final rows = (await db.query('SELECT * FROM products')).rows;
              final cursor =
                  (await db.query('SELECT cursor FROM _spsync_state'))
                      .rows
                      .single
                      .single;
              // Earlier empty preparation/inspection commits may survive alone.
              expect(rows.length, anyOf(0, 1));
              expect(cursor, rows.isEmpty ? null : '1');
              expect(
                  (await db.query('SELECT id FROM _spsync_rows')).rows.length,
                  rows.length);
            }
            if (phase == 'resolve') {
              final conflicts = await restored.conflicts();
              final price = (await db.query('SELECT price FROM products'))
                  .rows
                  .single
                  .single;
              expect(
                  price, conflicts.isEmpty ? BigInt.from(20) : BigInt.from(10));
              expect(outbox.length, conflicts.isEmpty ? 0 : 1);
              if (conflicts.isNotEmpty) {
                await restored.resolveConflict(
                    conflicts.single.id, SyncResolution.acceptRemote);
              }
            }
            await restored.runOnce();
            expect((await restored.conflicts()), isEmpty);
            expect(
                (await db.query('SELECT id FROM _spsync_outbox WHERE id>0'))
                    .rows,
                isEmpty);
            expect(
                (await db.query('PRAGMA integrity_check')).rows.single.single,
                'ok');
            await db.close();
            data.losePower();
            log.losePower();
            final twice = await _open(data, log);
            expect(
                (await twice.query('PRAGMA integrity_check'))
                    .rows
                    .single
                    .single,
                'ok');
            await twice.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  }
}
