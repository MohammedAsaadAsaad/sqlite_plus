import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';
import 'support/fault_storage.dart';

Future<MutableSqliteDatabase> open(FaultStorage data, FaultStorage log) async =>
    MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(data, log));

void main() {
  for (final phase in ['capture', 'ack', 'prune', 'track']) {
    for (final mode in ['delete', 'persist']) {
      for (final immediate in [false, true]) {
        test('$phase atomic recovery mode=$mode immediate=$immediate',
            () async {
          final seed = await openInMemory();
          await seed.execute('PRAGMA recursive_triggers=ON');
          await seed.execute(
              'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT)');
          final feed = await SqlitePlusChanges.open(database: seed);
          if (phase != 'track') {
            await feed.track(table: 'products');
            final c = await feed.consumer(name: 'c');
            await feed.transaction((tx) async {
              await tx.execute("INSERT INTO products VALUES(1,'milk')");
            });
            if (phase == 'ack' || phase == 'prune') {
              final batch = await c.read();
              if (phase == 'prune') await c.acknowledge(batch.checkpoint);
            }
          }
          final image = seed.exportImage();
          await seed.close();
          Future<(MutableSqliteDatabase, SqlitePlusChanges)> setup(
              Faults faults, FaultStorage data, FaultStorage journal) async {
            final db = await open(data, journal);
            await db.execute('PRAGMA journal_mode=$mode');
            await db.execute('PRAGMA recursive_triggers=ON');
            final changes = await SqlitePlusChanges.open(database: db);
            faults.operations = 0;
            return (db, changes);
          }

          Future<void> action(SqlitePlusChanges changes) async {
            if (phase == 'track') {
              await changes.track(table: 'products');
            } else if (phase == 'capture') {
              await changes.transaction((tx) async {
                await tx.execute("INSERT INTO products VALUES(2,'tea')");
              });
            } else if (phase == 'ack') {
              final c = await changes.consumer(name: 'c');
              await c.acknowledge(await changes.head());
            } else {
              await changes.pruneAcknowledged();
            }
          }

          final baseline = Faults()..immediatePersistence = immediate;
          final baseData = FaultStorage(image, baseline),
              baseLog = FaultStorage(Uint8List(0), baseline);
          final (baseDb, baseFeed) = await setup(baseline, baseData, baseLog);
          await action(baseFeed);
          final operations = baseline.operations;
          expect(operations, greaterThan(0));
          await baseDb.close();
          print('$phase $mode immediate=$immediate fault points: $operations');
          for (var point = 1; point <= operations; point++) {
            final faults = Faults()..immediatePersistence = immediate;
            final data = FaultStorage(image, faults),
                log = FaultStorage(Uint8List(0), faults);
            final (_, changes) = await setup(faults, data, log);
            faults.failAfter = point;
            await expectLater(action(changes), throwsA(isA<PowerLoss>()));
            data.losePower();
            log.losePower();
            faults.failAfter = null;
            final recovered = await open(data, log);
            final restored = await SqlitePlusChanges.open(database: recovered);
            final state = (await recovered
                    .query('SELECT next_batch,pruned_through FROM _spc_state'))
                .rows
                .single;
            final sources =
                (await recovered.query('SELECT enabled FROM _spc_sources'))
                    .rows;
            final count =
                (await recovered.query('SELECT count(*) FROM _spc_events'))
                    .rows
                    .single
                    .single as BigInt;
            if (phase == 'track') {
              expect(sources.length, anyOf(0, 1));
              final triggers = (await recovered.query(
                      "SELECT name FROM sqlite_schema WHERE type='trigger'"))
                  .rows
                  .length;
              expect(triggers, sources.isEmpty ? 0 : 6);
            } else if (phase == 'capture') {
              final rows =
                  (await recovered.query('SELECT count(*) FROM products'))
                      .rows
                      .single
                      .single;
              expect(rows, anyOf(BigInt.one, BigInt.two));
              expect(count, rows);
              expect(state[0], count + BigInt.one);
            } else if (phase == 'prune') {
              expect(state[1], anyOf(BigInt.zero, BigInt.one));
              expect(count, state[1] == BigInt.one ? BigInt.zero : BigInt.one);
              expect(
                  (await recovered.query(
                          'SELECT count(*) FROM _spc_batches WHERE id>0'))
                      .rows
                      .single
                      .single,
                  count);
            } else {
              final ack = (await recovered
                      .query('SELECT acked_batch FROM _spc_consumers'))
                  .rows
                  .single
                  .single;
              expect(ack, anyOf(BigInt.zero, BigInt.one));
              expect(
                  (await (await restored.consumer(name: 'c')).read())
                      .events
                      .length,
                  ack == BigInt.one ? 0 : 1);
            }
            await recovered.close();
            data.losePower();
            log.losePower();
            final twice = await open(data, log);
            expect(
                (await twice.query('PRAGMA integrity_check'))
                    .rows
                    .single
                    .single,
                'ok');
            await SqlitePlusChanges.open(database: twice);
            await twice.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  }
}
