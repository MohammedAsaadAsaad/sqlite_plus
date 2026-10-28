import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:margin_notes/note_store.dart';
import 'package:margin_notes/note_work.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'package:margin_notes/note.dart';

void main() {
  test('one transaction inserts every random note', () async {
    final image = await _emptyImage();
    final report = await insertRandomNotes(image, 4, singleTransaction: true);
    expect(report.inserted, 4);
    expect(report.elapsedMicros, greaterThan(0));
    expect(report.rssBefore, greaterThan(0));
    expect(report.rssPeak, greaterThanOrEqualTo(report.rssBefore));
    expect(report.cpuMicros, greaterThanOrEqualTo(0));
    final titles = await _titles(report.image);
    expect(titles, ['Random 1', 'Random 2', 'Random 3', 'Random 4']);
  });

  test('separate saves insert the same rows', () async {
    final image = await _emptyImage();
    final report = await insertRandomNotes(image, 3, singleTransaction: false);
    expect(report.inserted, 3);
    expect(report.singleTransaction, isFalse);
    expect(await _titles(report.image), ['Random 1', 'Random 2', 'Random 3']);
  });

  test('delete all removes every tracked note in one save', () async {
    final seeded = await insertRandomNotes(
      await _emptyImage(),
      4,
      singleTransaction: true,
    );
    final cleared = await deleteAllNotes(seeded.image);
    expect(await _titles(cleared), isEmpty);
  });

  test(
    'vacuum keeps the notes and reports the image before and after',
    () async {
      final seeded = await insertRandomNotes(
        await _emptyImage(),
        3,
        singleTransaction: true,
      );
      final vacuumed = await vacuumNotes(seeded.image);
      expect(vacuumed.before.noteCount, BigInt.from(3));
      expect(vacuumed.after.noteCount, BigInt.from(3));
      expect(vacuumed.before.pageCount, greaterThan(0));
      expect(vacuumed.after.pageCount, greaterThan(0));
      expect(
        vacuumed.after.pageCount,
        lessThanOrEqualTo(vacuumed.before.pageCount),
      );
      expect(await _titles(vacuumed.image), [
        'Random 1',
        'Random 2',
        'Random 3',
      ]);
    },
  );

  test(
    'the store runs the insert in another isolate and can clear it',
    () async {
      final directory = Directory.systemTemp.createTempSync('margin-bench');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = NoteStore(directory);
      await store.open();
      final report = await store.insertRandom(2, singleTransaction: true);
      expect(report.inserted, 2);
      expect(store.notes.map((note) => note.title).toSet(), {
        'Random 1',
        'Random 2',
      });
      expect(store.busy, isFalse);

      final details = await store.details();
      expect(details.path, endsWith('margin.db'));
      expect(details.fileBytes, greaterThan(0));
      expect(details.noteCount, BigInt.two);
      expect(details.objects.map((object) => object.name), contains('notes'));
      expect(details.pageCount, greaterThan(0));

      final vacuumed = await store.vacuum();
      expect(vacuumed.after.noteCount, BigInt.two);
      expect(store.notes, hasLength(2));

      await store.deleteAll();
      expect(store.notes, isEmpty);
      final after = await store.details();
      expect(after.noteCount, BigInt.zero);
      await store.close();
    },
  );
}

Future<Uint8List> _emptyImage() async {
  final database = await MutableSqliteDatabase.create();
  final connection = MutableDatabaseConnection(database, closeDatabase: true);
  final context = DbContext(connection, DbModel([noteType]));
  await context.migrations.ensureCreated();
  final image = database.exportImage();
  await context.close();
  return image;
}

Future<List<String>> _titles(Uint8List image) async {
  final database = await MutableSqliteDatabase.fromImage(image);
  final connection = MutableDatabaseConnection(database, closeDatabase: true);
  final context = DbContext(connection, DbModel([noteType]));
  final notes = context.set(noteType);
  final rows = await notes.query.orderBy([noteId.asc()]).toList();
  final titles = rows.map((note) => note.title).toList();
  await context.close();
  return titles;
}
