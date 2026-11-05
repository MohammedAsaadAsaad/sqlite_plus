import 'dart:io';

import 'package:sqlite_plus_orm_example/shared_shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-shared-');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
        return;
      } on PathAccessException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('one memory database stores a book and a note', () async {
    final shelf = await runSharedMemory();
    expect(shelf.bookTitle, 'Kept Garden');
    expect(shelf.noteBody, 'margin');
  });

  test('a file open keeps the note, and a second open is rejected', () async {
    final path = '${directory.path}/notes.db';
    expect(await runFileKeepsRow(path), 'kept');
    expect(await runSecondFileOpenRejected(path), isTrue);
    expect(File('$path-journal').existsSync(), isTrue);
  });

  test('a second save is rejected and two queries both finish', () async {
    expect(await runSecondSaveRejected(), isTrue);
    expect(await runQueuedQueries(), ['Kept Garden', 'margin']);
  });
}
