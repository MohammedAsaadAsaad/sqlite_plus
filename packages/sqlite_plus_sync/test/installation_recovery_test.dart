import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';
import 'support/fault_storage.dart';

void main() {
  for (final phase in ['initialize', 'register']) {
    for (final mode in ['delete', 'persist']) {
      for (final immediate in [false, true]) {
        test('$phase installation recovery $mode immediate=$immediate',
            () async {
          final server = MemorySyncServer();
          final seed = await openInMemory();
          await seed.execute('PRAGMA recursive_triggers=ON');
          await seed.execute(
              'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER)');
          final feed = await SqlitePlusChanges.open(database: seed);
          if (phase == 'register') {
            await SqlitePlusSync.open(
                changes: feed, transport: server, scope: 'shop');
          }
          final image = seed.exportImage();
          await seed.close();
          Future<(MutableSqliteDatabase, SqlitePlusChanges, SqlitePlusSync?)>
              setup(Faults faults, FaultStorage data, FaultStorage log) async {
            final db = await MutableSqliteDatabase.fromJournalPager(
                await RollbackJournalPager.open(data, log));
            await db.execute('PRAGMA journal_mode=$mode');
            await db.execute('PRAGMA recursive_triggers=ON');
            final changes = await SqlitePlusChanges.open(database: db);
            final sync = phase == 'register'
                ? await SqlitePlusSync.open(
                    changes: changes, transport: server, scope: 'shop')
                : null;
            faults.operations = 0;
            return (db, changes, sync);
          }

          Future<void> action(
              SqlitePlusChanges changes, SqlitePlusSync? sync) async {
            if (phase == 'initialize') {
              await SqlitePlusSync.open(
                  changes: changes, transport: server, scope: 'shop');
            } else {
              await sync!
                  .register(table: 'products', columns: ['name', 'price']);
            }
          }

          final base = Faults()..immediatePersistence = immediate;
          final (db, changes, sync) = await setup(base,
              FaultStorage(image, base), FaultStorage(Uint8List(0), base));
          await action(changes, sync);
          final count = base.operations;
          await db.close();
          expect(count, greaterThan(0));
          print('$phase $mode immediate=$immediate fault points: $count');
          for (var point = 1; point <= count; point++) {
            final faults = Faults()..immediatePersistence = immediate;
            final data = FaultStorage(image, faults),
                log = FaultStorage(Uint8List(0), faults);
            final (_, changes, sync) = await setup(faults, data, log);
            faults.failAfter = point;
            await expectLater(action(changes, sync), throwsA(isA<PowerLoss>()));
            data.losePower();
            log.losePower();
            faults.failAfter = null;
            final db = await MutableSqliteDatabase.fromJournalPager(
                await RollbackJournalPager.open(data, log));
            await db.execute('PRAGMA recursive_triggers=ON');
            final recovered = await SqlitePlusChanges.open(database: db);
            final restored = await SqlitePlusSync.open(
                changes: recovered, transport: server, scope: 'shop');
            await restored
                .register(table: 'products', columns: ['name', 'price']);
            expect((await db.query('SELECT name FROM _spsync_tables')).rows, [
              ['products']
            ]);
            expect((await recovered.sources()).single.table, 'products');
            expect(
                (await db.query('PRAGMA integrity_check')).rows.single.single,
                'ok');
            await db.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  }
}
