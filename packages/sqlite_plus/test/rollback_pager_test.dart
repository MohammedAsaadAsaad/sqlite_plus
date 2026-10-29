import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class SimulatedCrash implements Exception {}

/// A model with volatile writes and a separately persisted image. Crash drops
/// unsynced bytes. Fault injection stops after each mutating storage operation.
final class CrashController {
  int operations = 0;
  int? crashAt;
  bool persistUnsynced = false;
  void afterOperation() {
    if (++operations == crashAt) throw SimulatedCrash();
  }
}

final class ModelFile implements DurableStorageBackend {
  ModelFile(Uint8List bytes, this.controller)
      : volatile = Uint8List.fromList(bytes),
        durable = Uint8List.fromList(bytes);
  Uint8List volatile;
  Uint8List durable;
  final CrashController controller;
  void crash() {
    volatile = Uint8List.fromList(durable);
  }

  void persist() {
    durable = Uint8List.fromList(volatile);
  }

  @override
  Future<int> length() async => volatile.length;
  @override
  Future<int> read(int offset, Uint8List buffer) async {
    if (offset >= volatile.length) return 0;
    final count = min(buffer.length, volatile.length - offset);
    buffer.setRange(0, count, volatile, offset);
    return count;
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    if (offset + bytes.length > volatile.length) {
      final grown = Uint8List(offset + bytes.length)
        ..setRange(0, volatile.length, volatile);
      volatile = grown;
    }
    volatile.setRange(offset, offset + bytes.length, bytes);
    if (controller.persistUnsynced) persist();
    controller.afterOperation();
  }

  @override
  Future<void> truncate(int size) async {
    final next = Uint8List(size);
    next.setRange(0, min(size, volatile.length), volatile);
    volatile = next;
    if (controller.persistUnsynced) persist();
    controller.afterOperation();
  }

  @override
  Future<void> sync() async {
    persist();
    controller.afterOperation();
  }

  @override
  Future<void> close() async {}
}

Uint8List originalImage() =>
    File('test/fixtures/sqlite-512.db').readAsBytesSync();
Uint8List updatedImage(Uint8List image, int userVersion) {
  final result = Uint8List.fromList(image);
  final data = ByteData.sublistView(result);
  data.setUint32(60, userVersion);
  data.setUint32(24, data.getUint32(24) + 1);
  data.setUint32(92, data.getUint32(24));
  return result;
}

void main() {
  for (final persistUnsynced in [false, true]) {
    test(
        'crash at every commit operation, unsynced persistence=$persistUnsynced',
        () async {
      final original = originalImage();
      final next = updatedImage(original, 987);
      final baseline = CrashController()..persistUnsynced = persistUnsynced;
      final db = ModelFile(original, baseline);
      final journal = ModelFile(Uint8List(0), baseline);
      final pager = await RollbackJournalPager.open(db, journal);
      await pager.commitImage(next);
      final operations = baseline.operations;
      expect(db.durable, next);
      await pager.close();
      // Every database/journal write, truncate and sync gets its own restart.
      for (var point = 1; point <= operations; point++) {
        final controller = CrashController()
          ..persistUnsynced = persistUnsynced
          ..crashAt = point;
        final database = ModelFile(original, controller);
        final log = ModelFile(Uint8List(0), controller);
        final writer = await RollbackJournalPager.open(database, log);
        await expectLater(
            writer.commitImage(next), throwsA(isA<SimulatedCrash>()),
            reason: 'operation $point');
        await expectLater(writer.readImage(), throwsStateError);
        database.crash();
        log.crash();
        controller.crashAt = null;
        final reopened = await RollbackJournalPager.open(database, log);
        final recovered = await reopened.readImage();
        expect(recovered, anyOf(equals(original), equals(next)),
            reason: 'operation $point');
        // Recovery itself must be repeatable.
        await reopened.close();
        database.crash();
        log.crash();
        final twice = await RollbackJournalPager.open(database, log);
        expect(await twice.readImage(), recovered);
        await twice.close();
      }
    });
  }
  test('crash at every recovery operation keeps recovery restartable',
      () async {
    final original = originalImage();
    final next = updatedImage(original, 99);
    // Invalidate, one changed-page record, valid header, then the database write.
    final controller = CrashController()..persistUnsynced = true;
    final db = ModelFile(original, controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(db, journal);
    controller.crashAt = 6; // database write, before database sync
    await expectLater(pager.commitImage(next), throwsA(isA<SimulatedCrash>()));
    final hot = Uint8List.fromList(journal.durable);
    for (var point = 1; point <= 5; point++) {
      final faults = CrashController()
        ..persistUnsynced = true
        ..crashAt = point;
      final database = ModelFile(next, faults);
      final log = ModelFile(hot, faults);
      await expectLater(RollbackJournalPager.open(database, log),
          throwsA(isA<SimulatedCrash>()));
      database.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await RollbackJournalPager.open(database, log);
      expect(await recovered.readImage(), original);
      await recovered.close();
    }
  });
  test('corrupt journals fail closed before altering the database', () async {
    final original = originalImage();
    final controller = CrashController()..persistUnsynced = true;
    final database = ModelFile(original, controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(database, journal);
    controller.crashAt = 6;
    final next = updatedImage(original, 72);
    await expectLater(pager.commitImage(next), throwsA(isA<SimulatedCrash>()));
    final hot = Uint8List.fromList(journal.durable);
    for (final offset in [
      0,
      8,
      16,
      20,
      24,
      512,
      512 + 4 + 312,
      hot.length - 1
    ]) {
      final faults = CrashController();
      final corrupt = Uint8List.fromList(hot)..[offset] ^= 1;
      final db = ModelFile(next, faults);
      final log = ModelFile(corrupt, faults);
      await expectLater(
          RollbackJournalPager.open(db, log), throwsFormatException,
          reason: 'offset $offset');
      expect(db.volatile, next);
      expect(faults.operations, 0);
    }
  });
  test('repeated commits reuse an existing persistent journal', () async {
    final controller = CrashController();
    final db = ModelFile(originalImage(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(db, journal);
    for (var version = 0; version < 3; version++) {
      final next = updatedImage(await pager.readImage(), version);
      await pager.commitImage(next);
      expect(db.durable, next);
      expect(journal.durable.take(28), everyElement(0));
    }
    await pager.close();
    await expectLater(pager.readImage(), throwsStateError);
  });
  test('replacement validation happens before any journal or database writes',
      () async {
    final controller = CrashController();
    final db = ModelFile(originalImage(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(db, journal);
    for (final image in [
      Uint8List(99),
      originalImage()..[18] = 2,
      originalImage()..[16] = 4,
      originalImage().sublist(0, 512)
    ]) {
      await expectLater(pager.commitImage(image), throwsFormatException);
      expect(controller.operations, 0);
    }
    expect(await pager.readImage(), originalImage());
    await pager.close();
  });
  test('a one-page edit journals only that before-image', () async {
    final controller = CrashController();
    final original = originalImage();
    final db = ModelFile(original, controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(db, journal);
    await pager.commitImage(updatedImage(original, 4));
    final pageSize = 512;
    expect(journal.durable.length, 512 + pageSize + 8);
    expect(db.durable, updatedImage(original, 4));
    await pager.close();
  });
}
