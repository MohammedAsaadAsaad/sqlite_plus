import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:margin_notes/note_store.dart';

void main() {
  test('a saved note reopens from the image', () async {
    final directory = Directory.systemTemp.createTempSync('margin-store');
    addTearDown(() => directory.deleteSync(recursive: true));

    final store = NoteStore(directory);
    await store.open();
    final note = store.draft()
      ..title = 'تجربة'
      ..body = 'سطر';
    await store.save(note);
    expect(store.notes, hasLength(1));
    expect(store.notes.single.id, isNotNull);
    expect(store.notes.single.title, 'تجربة');
    await store.close();

    final reopened = NoteStore(directory);
    await reopened.open();
    expect(reopened.notes, hasLength(1));
    expect(reopened.notes.single.title, 'تجربة');
    expect(reopened.notes.single.body, 'سطر');
    expect(reopened.notes.single.pinned, isFalse);
    await reopened.close();
  });

  test('a blank draft is not inserted', () async {
    final directory = Directory.systemTemp.createTempSync('margin-blank');
    addTearDown(() => directory.deleteSync(recursive: true));

    final store = NoteStore(directory);
    await store.open();
    await store.save(store.draft());
    expect(store.notes, isEmpty);
    await store.close();

    final reopened = NoteStore(directory);
    await reopened.open();
    expect(reopened.notes, isEmpty);
    await reopened.close();
  });

  test('a pinned note sorts ahead of a newer note', () async {
    final directory = Directory.systemTemp.createTempSync('margin-pin');
    addTearDown(() => directory.deleteSync(recursive: true));

    final store = NoteStore(directory);
    await store.open();
    final older = store.draft()
      ..title = 'مثبتة'
      ..body = 'أولاً';
    await store.save(older);
    final pinned = store.notes.single;
    await store.togglePin(pinned);
    final newer = store.draft()
      ..title = 'أحدث'
      ..body = 'ثانياً';
    await store.save(newer);

    expect(store.notes, hasLength(2));
    expect(store.notes.first.title, 'مثبتة');
    expect(store.notes.first.pinned, isTrue);
    expect(store.notes.last.title, 'أحدث');
    await store.close();
  });

  test('search keeps notes whose title or body contains the query', () async {
    final directory = Directory.systemTemp.createTempSync('margin-search');
    addTearDown(() => directory.deleteSync(recursive: true));

    final store = NoteStore(directory);
    await store.open();
    await store.save(
      store.draft()
        ..title = 'حديقة'
        ..body = 'هامش',
    );
    await store.save(
      store.draft()
        ..title = 'أطلس'
        ..body = 'جنوب',
    );
    store.setSearch('حديقة');
    expect(store.visible.map((note) => note.title), ['حديقة']);
    store.setSearch('جنوب');
    expect(store.visible.map((note) => note.title), ['أطلس']);
    await store.close();
  });
}
