import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/prepared_fault_storage.dart';

Future<MutableSqliteDatabase> open(
        FaultStorage data, FaultStorage journal) async =>
    MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(data, journal));
void main() {
  for (final mode in ['delete', 'persist']) {
    for (final immediate in [false, true]) {
      test('prepared autocommit recovery $mode immediate=$immediate', () async {
        final seed = await openInMemory();
        await seed.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
        await seed.execute('INSERT INTO t VALUES(1,10)');
        final image = seed.exportImage();
        await seed.close();
        Future<(MutableSqliteDatabase, SqlPreparedStatement)> setup(
            FaultStorage data, FaultStorage journal, Faults faults) async {
          final db = await open(data, journal);
          await db.execute('PRAGMA journal_mode=$mode');
          faults.operations = 0;
          final prepared = await db
              .prepare('UPDATE t SET n=? WHERE id=? AND n>=0 RETURNING n');
          expect(faults.operations, 0,
              reason: 'Preparation must not write storage');
          return (db, prepared);
        }

        final f = Faults()..immediatePersistence = immediate;
        final data = FaultStorage(image, f),
            journal = FaultStorage(Uint8List(0), f);
        final (db, prepared) = await setup(data, journal, f);
        await prepared.execute([99, 1]);
        final operations = f.operations;
        expect(operations, greaterThan(0));
        await prepared.close();
        await db.close();
        for (var point = 1; point <= operations; point++) {
          final faults = Faults()..immediatePersistence = immediate;
          final bytes = FaultStorage(image, faults),
              log = FaultStorage(Uint8List(0), faults);
          final (_, stmt) = await setup(bytes, log, faults);
          faults.failAfter = point;
          await expectLater(stmt.execute([99, 1]), throwsA(isA<PowerLoss>()));
          faults.failAfter = null;
          bytes.losePower();
          log.losePower();
          final recovered = await open(bytes, log);
          expect((await recovered.query('SELECT n FROM t')).rows.single.single,
              anyOf(BigInt.from(10), BigInt.from(99)));
          expect(
              (await recovered.query('PRAGMA integrity_check'))
                  .rows
                  .single
                  .single,
              'ok');
          await recovered.close();
        }
      });
    }
  }
}
