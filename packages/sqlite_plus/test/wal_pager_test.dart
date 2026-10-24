import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart'
    show ModelFile, CrashController, SimulatedCrash;

Uint8List walBase() => File('test/fixtures/wal-base.db').readAsBytesSync();
Uint8List changed(Uint8List base, int version) {
  final result = WalSnapshot.rollbackCopy(base, Uint8List(0));
  final data = ByteData.sublistView(result);
  data.setUint32(60, version);
  data.setUint32(24, data.getUint32(24) + 1);
  data.setUint32(92, data.getUint32(24));
  return result;
}

Future<WalPager> open(ModelFile db, ModelFile wal,
        {int maxWalBytes = 256 * 1024 * 1024}) =>
    WalPager.open(db, wal,
        exclusiveOwnership: true,
        walIndexAbsent: true,
        maxWalBytes: maxWalBytes);

final class TornWriteFile implements DurableStorageBackend {
  TornWriteFile(this.inner);
  final ModelFile inner;
  @override
  Future<int> length() => inner.length();
  @override
  Future<int> read(int offset, Uint8List buffer) => inner.read(offset, buffer);
  @override
  Future<void> write(int offset, Uint8List bytes) => inner.write(
      offset,
      inner.controller.crashAt == inner.controller.operations + 1 &&
              bytes.length > 1
          ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)
          : bytes);
  @override
  Future<void> truncate(int size) => inner.truncate(size);
  @override
  Future<void> sync() => inner.sync();
  @override
  Future<void> close() => inner.close();
}

void main() {
  for (final retain in [false, true]) {
    test('WAL commit crash after every storage operation retain=$retain',
        () async {
      final baseline = CrashController();
      final source = walBase();
      final next = changed(source, 72);
      final reference = await open(
          ModelFile(source, baseline), ModelFile(Uint8List(0), baseline));
      await reference.commitImage(next);
      final count = baseline.operations;
      await reference.close();
      for (var point = 1; point <= count; point++) {
        final faults = CrashController()..persistUnsynced = retain;
        final db = ModelFile(source, faults);
        final log = ModelFile(Uint8List(0), faults);
        final pager = await open(db, log);
        faults.crashAt = point;
        await expectLater(
            pager.commitImage(next), throwsA(isA<SimulatedCrash>()));
        await expectLater(pager.readImage(), throwsStateError);
        db.crash();
        log.crash();
        faults.crashAt = null;
        final recovered = await open(db, log);
        expect(
            await recovered.readImage(),
            anyOf(equals(WalSnapshot.rollbackCopy(source, Uint8List(0))),
                equals(next)),
            reason: 'crash $point');
        await recovered.close();
      }
    });
    test('checkpoint crash after every storage operation retain=$retain',
        () async {
      final baseline = CrashController();
      final source = walBase();
      final next = changed(source, 73);
      final a = ModelFile(source, baseline);
      final b = ModelFile(Uint8List(0), baseline);
      final reference = await open(a, b);
      await reference.commitImage(next);
      final committedLog = Uint8List.fromList(b.durable);
      baseline.operations = 0;
      await reference.checkpoint();
      final count = baseline.operations;
      await reference.close();
      for (var point = 1; point <= count; point++) {
        final faults = CrashController()..persistUnsynced = retain;
        final db = ModelFile(source, faults);
        final log = ModelFile(committedLog, faults);
        final pager = await open(db, log);
        faults.crashAt = point;
        await expectLater(pager.checkpoint(), throwsA(isA<SimulatedCrash>()));
        db.crash();
        log.crash();
        faults.crashAt = null;
        final recovered = await open(db, log);
        expect(await recovered.readImage(), next,
            reason: 'checkpoint crash $point');
        await recovered.checkpoint();
        expect(log.durable, isEmpty);
        expect(await recovered.readImage(), next);
        await recovered.close();
      }
    });
  }
  test('append, reopen, suffix discard, checkpoint and restart', () async {
    final faults = CrashController();
    final db = ModelFile(walBase(), faults);
    final log = ModelFile(Uint8List(0), faults);
    var pager = await open(db, log);
    final first = changed(walBase(), 1);
    await pager.commitImage(first);
    final oldMain = Uint8List.fromList(db.durable);
    final second = changed(first, 2);
    await pager.commitImage(second);
    expect(db.durable, oldMain);
    expect(await pager.readImage(), second);
    await pager.close();
    // A stale/truncated transaction tail may remain after the committed prefix.
    await log.write(log.volatile.length, Uint8List.fromList([1, 2, 3]));
    await log.sync();
    pager = await open(db, log);
    await pager.commitImage(changed(second, 3));
    await pager.checkpoint();
    expect(log.durable, isEmpty);
    final third = await pager.readImage();
    await pager.commitImage(changed(third, 4));
    expect(DatabaseHeader.decode(await pager.readImage()).userVersion, 4);
    await pager.close();
  });
  test('WAL image integration delays writes until transaction commit',
      () async {
    final faults = CrashController();
    final db = ModelFile(walBase(), faults);
    final log = ModelFile(Uint8List(0), faults);
    final pager = await open(db, log);
    final database = await MutableSqliteDatabase.fromImagePager(pager);
    await database.execute('BEGIN');
    await database.execute("UPDATE notes SET value='wal' WHERE id=1");
    expect(faults.operations, 0);
    await database.execute('COMMIT');
    expect(log.durable, isNotEmpty);
    expect((await database.query('SELECT value FROM notes WHERE id=1')).rows, [
      ['wal']
    ]);
    await pager.checkpoint();
    await database.close();
  });
  test('ownership, distinct backends, format, bounds and no write on rejection',
      () async {
    final faults = CrashController();
    final db = ModelFile(walBase(), faults);
    final log = ModelFile(Uint8List(0), faults);
    await expectLater(
        WalPager.open(db, log, exclusiveOwnership: false, walIndexAbsent: true),
        throwsUnsupportedError);
    await expectLater(
        WalPager.open(db, log, exclusiveOwnership: true, walIndexAbsent: false),
        throwsUnsupportedError);
    await expectLater(open(db, db), throwsArgumentError);
    final rollback = ModelFile(changed(walBase(), 1), faults);
    await expectLater(open(rollback, log), throwsUnsupportedError);
    final pager = await open(db, log, maxWalBytes: 32);
    await expectLater(
        pager.commitImage(changed(walBase(), 1)), throwsStateError);
    expect(faults.operations, 0);
    expect(await pager.readImage(),
        WalSnapshot.rollbackCopy(walBase(), Uint8List(0)));
    await pager.close();
  });
  test('WAL committed growth survives partial checkpoint before main grows',
      () async {
    final source = walBase();
    final mutable = await MutableSqliteDatabase.fromImage(
        WalSnapshot.rollbackCopy(source, Uint8List(0)));
    await mutable
        .execute('UPDATE notes SET value=? WHERE id=1', ['large-' * 6000]);
    final grown = mutable.exportImage();
    await mutable.close();
    expect(grown.length, greaterThan(source.length));
    final faults = CrashController()..persistUnsynced = true;
    final main = ModelFile(source, faults);
    final log = ModelFile(Uint8List(0), faults);
    final pager = await open(main, log);
    await pager.commitImage(grown);
    faults.crashAt =
        faults.operations + 2; // WAL sync, then main page-one write.
    await expectLater(pager.checkpoint(), throwsA(isA<SimulatedCrash>()));
    main.crash();
    log.crash();
    faults.crashAt = null;
    final recovered = await open(main, log);
    expect(await recovered.readImage(), grown);
    await recovered.checkpoint();
    expect(await recovered.readImage(), grown);
    await recovered.close();
  });
  test(
      'full-image WAL commits may shrink a database without exposing old pages',
      () async {
    final source = walBase();
    final empty = Uint8List.fromList(source.sublist(0, 512))
      ..[18] = 1
      ..[19] = 1;
    // Frame a valid empty schema page rather than retaining its original cells.
    empty.fillRange(100, 512, 0);
    empty[100] = 13;
    final data = ByteData.sublistView(empty);
    data.setUint16(105, 512);
    data.setUint32(28, 1);
    data.setUint32(32, 0);
    data.setUint32(36, 0);
    data.setUint32(92, data.getUint32(24));
    final faults = CrashController();
    final main = ModelFile(source, faults);
    final log = ModelFile(Uint8List(0), faults);
    final pager = await open(main, log);
    await pager.commitImage(empty);
    expect(await pager.readImage(), empty);
    await pager.checkpoint();
    expect(main.durable.length, 512);
    expect(log.durable, isEmpty);
    expect(await pager.readImage(), empty);
    await pager.close();
  });
  test('torn WAL append preserves the previously acknowledged transaction',
      () async {
    final source = walBase();
    final first = changed(source, 11);
    final second = changed(first, 12);
    final baseline = CrashController();
    final a = ModelFile(source, baseline);
    final b = ModelFile(Uint8List(0), baseline);
    final initial = await open(a, b);
    await initial.commitImage(first);
    final prefix = Uint8List.fromList(b.durable);
    await initial.close();
    for (final page in [1, 2, first.length ~/ 512]) {
      final faults = CrashController()..persistUnsynced = true;
      final main = ModelFile(source, faults);
      final log = ModelFile(prefix, faults);
      final pager = await WalPager.open(main, TornWriteFile(log),
          exclusiveOwnership: true, walIndexAbsent: true);
      faults.crashAt = 2 + page; // Prefix truncate/sync, then frame writes.
      await expectLater(
          pager.commitImage(second), throwsA(isA<SimulatedCrash>()));
      main.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await open(main, log);
      expect(await recovered.readImage(), first);
      await recovered.close();
    }
  });
  test('torn checkpoint page writes recover the acknowledged WAL image',
      () async {
    final source = walBase();
    final next = changed(source, 13);
    final baseline = CrashController();
    final a = ModelFile(source, baseline);
    final b = ModelFile(Uint8List(0), baseline);
    final initial = await open(a, b);
    await initial.commitImage(next);
    final committed = Uint8List.fromList(b.durable);
    await initial.close();
    for (final page in [1, 2, next.length ~/ 512]) {
      final faults = CrashController()..persistUnsynced = true;
      final main = ModelFile(source, faults);
      final log = ModelFile(committed, faults);
      final pager = await WalPager.open(TornWriteFile(main), log,
          exclusiveOwnership: true, walIndexAbsent: true);
      faults.crashAt = 1 + page; // WAL sync, then checkpoint writes.
      await expectLater(pager.checkpoint(), throwsA(isA<SimulatedCrash>()));
      main.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await open(main, log);
      expect(await recovered.readImage(), next);
      await recovered.close();
    }
  });
}
