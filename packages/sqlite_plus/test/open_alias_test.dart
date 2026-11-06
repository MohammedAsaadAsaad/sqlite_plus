import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

int _textEncoding(Uint8List image) => ByteData.sublistView(image).getUint32(56);

void main() {
  test('openInMemory inserts a row the same way create does', () async {
    final opened = await openInMemory();
    final created = await MutableSqliteDatabase.create();
    addTearDown(opened.close);
    addTearDown(created.close);
    for (final database in [opened, created]) {
      await database.execute(
          'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)');
      await database.execute('INSERT INTO notes (body) VALUES (?)', ['kept']);
    }
    expect((await opened.query('SELECT body FROM notes')).rows, [
      ['kept']
    ]);
    expect((await created.query('SELECT body FROM notes')).rows, [
      ['kept']
    ]);
  });

  test('openInMemory uses the same empty image as create', () async {
    final opened = await openInMemory(pageSize: 8192, encoding: 2);
    final created =
        await MutableSqliteDatabase.create(pageSize: 8192, encoding: 2);
    addTearDown(opened.close);
    addTearDown(created.close);
    expect(opened.exportImage(), created.exportImage());
    expect(opened.exportImage().length, 8192);
    expect(_textEncoding(opened.exportImage()), 2);
  });

  test('openInMemory accepts the page-size and encoding bounds', () async {
    final small = await openInMemory(pageSize: 512, encoding: 1);
    final large = await openInMemory(pageSize: 65536, encoding: 3);
    addTearDown(small.close);
    addTearDown(large.close);
    expect(small.exportImage().length, 512);
    expect(_textEncoding(small.exportImage()), 1);
    expect(large.exportImage().length, 65536);
    expect(_textEncoding(large.exportImage()), 3);
  });

  test('openInMemory rejects the same invalid formats as create', () {
    for (final pageSize in [0, 511, 513, 1000, 65537]) {
      expect(() => openInMemory(pageSize: pageSize), throwsArgumentError);
      expect(() => MutableSqliteDatabase.create(pageSize: pageSize),
          throwsArgumentError);
    }
    for (final encoding in [0, 4]) {
      expect(() => openInMemory(encoding: encoding), throwsArgumentError);
      expect(() => MutableSqliteDatabase.create(encoding: encoding),
          throwsArgumentError);
    }
  });

  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-open-alias-');
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

  String provision({bool wal = false}) {
    final path = '${directory.path}/data.db';
    File(path).writeAsBytesSync(
        File(wal ? 'test/fixtures/wal-base.db' : 'test/fixtures/write.db')
            .readAsBytesSync());
    File('$path${wal ? '-wal' : '-journal'}').writeAsBytesSync([]);
    return path;
  }

  test('openDatabase reads the same row as DatabaseOwner.open', () async {
    final path = provision();
    final aliased = await openDatabase(path, directoryEntriesDurable: true);
    addTearDown(aliased.close);
    expect(
        (await aliased.client.query('SELECT id FROM notes WHERE id=1')).rows, [
      [BigInt.one]
    ]);
    await aliased.close();
    final owner = await DatabaseOwner.open(path, directoryEntriesDurable: true);
    addTearDown(owner.close);
    expect((await owner.client.query('SELECT id FROM notes WHERE id=1')).rows, [
      [BigInt.one]
    ]);
  });

  test('openDatabase rejects an unattested directory entry', () async {
    final path = provision();
    await expectLater(openDatabase(path, directoryEntriesDurable: false),
        throwsUnsupportedError);
    await expectLater(DatabaseOwner.open(path, directoryEntriesDurable: false),
        throwsUnsupportedError);
  });

  test('openDatabase rejects a missing wal sidecar', () async {
    final path = provision();
    await expectLater(
        openDatabase(path, directoryEntriesDurable: true, wal: true),
        throwsStateError);
    expect(File('$path-wal').existsSync(), isFalse);
    await expectLater(
        DatabaseOwner.open(path, directoryEntriesDurable: true, wal: true),
        throwsStateError);
    expect(File('$path-wal').existsSync(), isFalse);
  });

  test('openDatabase creates a missing file and reads it back', () async {
    final path = '${directory.path}/shelf.db';
    final opened = await openDatabase(path);
    addTearDown(opened.close);
    await opened.execute(
        'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT, body TEXT)');
    await opened.execute('INSERT INTO note(title, body) VALUES (?, ?), (?, ?)',
        ['Kept Garden', 'a garden kept in the margin', 'Other Atlas', 'south']);
    expect(
        (await opened.client.query(
                'SELECT title FROM note WHERE title LIKE ? ORDER BY title',
                ['%Garden%']))
            .rows,
        [
          ['Kept Garden']
        ]);
    await opened.close();
    expect(File(path).existsSync(), isTrue);
    expect(File('$path-journal').existsSync(), isTrue);
    final again = await openDatabase(path);
    addTearDown(again.close);
    expect((await again.client.query('SELECT title FROM note')).rows, [
      ['Kept Garden'],
      ['Other Atlas']
    ]);
  });

  test('openDatabase creates a missing parent directory', () async {
    final path = '${directory.path}/nested/shelf.db';
    final opened = await openDatabase(path);
    addTearDown(opened.close);
    expect(File(path).existsSync(), isTrue);
    expect(File('$path-journal').existsSync(), isTrue);
    await opened.execute('CREATE TABLE note (title TEXT)');
    await opened.execute('INSERT INTO note(title) VALUES (?)', ['Kept Garden']);
    await opened.close();
    final again = await openDatabase(path);
    addTearDown(again.close);
    expect((await again.client.query('SELECT title FROM note')).rows, [
      ['Kept Garden']
    ]);
  });

  test('openDatabase keeps an existing database and adds a missing journal',
      () async {
    final path = '${directory.path}/kept.db';
    File(path)
        .writeAsBytesSync(File('test/fixtures/write.db').readAsBytesSync());
    final before = File(path).readAsBytesSync();
    expect(File('$path-journal').existsSync(), isFalse);
    final opened = await openDatabase(path);
    addTearDown(opened.close);
    expect(File(path).readAsBytesSync(), before);
    expect(File('$path-journal').existsSync(), isTrue);
    expect(
        (await opened.client.query('SELECT id FROM notes WHERE id=1')).rows, [
      [BigInt.one]
    ]);
  });

  test('openDatabase leaves an empty existing file untouched', () async {
    final path = '${directory.path}/empty.db';
    File(path).writeAsBytesSync(const []);
    await expectLater(openDatabase(path), throwsStateError);
    expect(File(path).lengthSync(), 0);
  });

  test('openDatabase writes nothing when durability is refused', () async {
    final path = '${directory.path}/refused.db';
    await expectLater(openDatabase(path, directoryEntriesDurable: false),
        throwsUnsupportedError);
    expect(File(path).existsSync(), isFalse);
    expect(File('$path-journal').existsSync(), isFalse);
  });

  test('openDatabase does not create a missing wal database', () async {
    final path = '${directory.path}/wal-missing.db';
    await expectLater(
        openDatabase(path, wal: true), throwsA(isA<FileSystemException>()));
    expect(File(path).existsSync(), isFalse);
    expect(File('$path-wal').existsSync(), isFalse);
    expect(File('$path-journal').existsSync(), isFalse);
  });
}
