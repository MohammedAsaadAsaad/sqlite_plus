import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-app-');
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

  Future<DatabaseOwner> openNote(String name, {int version = 1}) {
    return openDatabase(
      '${directory.path}/$name',
      version: version,
      onCreate: (db, version) async {
        await db.execute(
            'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT UNIQUE, body TEXT, pages INT, cover BLOB)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('ALTER TABLE note ADD COLUMN extra TEXT');
      },
    );
  }

  test('insert, query, update, and delete keep the row in the file', () async {
    final db = await openNote('shelf.db');
    addTearDown(db.close);
    final id = await db.insert('note', {
      'title': 'Kept Garden',
      'body': 'a garden kept in the margin',
      'pages': 320,
      'cover': <int>[1, 2, 3],
    });
    expect(id, BigInt.one);
    final rows = await db.query(
      'note',
      columns: ['title', 'pages', 'cover'],
      where: 'title LIKE ?',
      whereArgs: ['%Garden%'],
      orderBy: 'title',
    );
    expect(rows, [
      {
        'title': 'Kept Garden',
        'pages': BigInt.from(320),
        'cover': Uint8List.fromList([1, 2, 3]),
      }
    ]);
    expect(
        await db.update('note', {'body': 'revised'},
            where: 'id = ?', whereArgs: [id]),
        1);
    expect(await db.delete('note', where: 'id = ?', whereArgs: [id]), 1);
    expect(await db.query('note'), isEmpty);
    await db.close();

    final again = await openNote('shelf.db');
    addTearDown(again.close);
    expect(await again.query('note'), isEmpty);
    expect(await again.rawQuery('PRAGMA user_version'), [
      {'user_version': BigInt.one}
    ]);
  });

  test('a transaction rolls back, and a nested savepoint keeps the outer row',
      () async {
    final db = await openNote('txn.db');
    addTearDown(db.close);
    await expectLater(db.transaction((txn) async {
      await txn.insert('note', {'title': 'Gone'});
      throw StateError('stop');
    }), throwsStateError);
    expect(await db.query('note'), isEmpty);

    await db.transaction((txn) async {
      await txn.insert('note', {'title': 'Kept'});
      await expectLater(txn.transaction((inner) async {
        await inner.insert('note', {'title': 'Inner'});
        throw StateError('inner');
      }), throwsStateError);
    });
    expect(await db.query('note', columns: ['title']), [
      {'title': 'Kept'}
    ]);
  });

  test('a batch commits together and can keep going after one SQL error',
      () async {
    final db = await openNote('batch.db');
    addTearDown(db.close);
    final batch = db.batch();
    batch.insert('note', {'title': 'One'});
    batch.insert('note', {'title': 'Two'});
    expect(await batch.commit(noResult: true), isEmpty);
    expect(await db.query('note', columns: ['title'], orderBy: 'title'), [
      {'title': 'One'},
      {'title': 'Two'}
    ]);

    final failing = db.batch();
    failing.insert('note', {'title': 'Three'});
    failing.rawInsert('INSERT INTO missing(title) VALUES (?)', ['nope']);
    await expectLater(failing.commit(), throwsA(isA<SqlException>()));
    expect(await db.query('note', where: "title = 'Three'"), isEmpty);

    final kept = db.batch();
    kept.insert('note', {'title': 'Four'});
    kept.rawInsert('INSERT INTO missing(title) VALUES (?)', ['nope']);
    final results = await kept.commit(continueOnError: true);
    expect(results.first, BigInt.from(3));
    expect(results.last, isA<SqlException>());
    expect(await db.query('note', where: "title = 'Four'"), hasLength(1));
  });

  test('conflicts, an empty insert, and a window stay inside the table',
      () async {
    final db = await openNote('bounds.db');
    addTearDown(db.close);
    await db.insert('note', {'title': 'Kept Garden'});
    await db.insert('note', {'title': 'Kept Garden'},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    expect(await db.query('note'), hasLength(1));
    await db.insert('note', {'title': 'Kept Garden', 'body': 'replaced'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    expect(await db.query('note', columns: ['body']), [
      {'body': 'replaced'}
    ]);
    await db.insert('note', {}, nullColumnHack: 'title');
    await db.insert('note', {'title': 'Other'});
    final page = await db.query('note',
        columns: ['title'],
        where: 'title IS NOT NULL',
        distinct: true,
        orderBy: 'title',
        limit: 1,
        offset: 1);
    expect(page, [
      {'title': 'Other'}
    ]);
    expect(await db.query('note', limit: 0), isEmpty);
    expect(() => db.query('note', columns: const []), throwsArgumentError);
    expect(() => db.query('note', limit: -1), throwsArgumentError);
    expect(() => db.insert('note', {}), throwsArgumentError);
    expect(() => db.update('note', {}), throwsArgumentError);
  });

  test('a bad name does not run a second statement', () async {
    final db = await openNote('names.db');
    addTearDown(db.close);
    await expectLater(
        db.insert('note (title) VALUES (\'x\'); --', {'title': 'nope'}),
        throwsA(isA<SqlException>()));
    expect(await db.query('note'), isEmpty);
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite%'");
    expect(tables, [
      {'name': 'note'}
    ]);
  });

  test('onCreate failure leaves version 0, and upgrade keeps the row',
      () async {
    final path = '${directory.path}/migrate.db';
    var created = 0;
    await expectLater(
        openDatabase(path, version: 1, onCreate: (db, version) async {
          await db.execute('CREATE TABLE note (title TEXT)');
          throw StateError('stop');
        }),
        throwsStateError);
    final opened =
        await openDatabase(path, version: 1, onCreate: (db, version) async {
      created++;
      await db
          .execute('CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT)');
      await db.insert('note', {'title': 'Kept'});
    });
    addTearDown(opened.close);
    expect(created, 1);
    await opened.close();

    final upgraded =
        await openDatabase(path, version: 2, onCreate: (db, version) async {},
            onUpgrade: (db, oldVersion, newVersion) async {
      expect(oldVersion, 1);
      expect(newVersion, 2);
      await db.execute('ALTER TABLE note ADD COLUMN body TEXT');
    });
    addTearDown(upgraded.close);
    expect(await upgraded.query('note', columns: ['title', 'body']), [
      {'title': 'Kept', 'body': null}
    ]);
    await upgraded.close();
    await expectLater(
        openDatabase(path, version: 1, onCreate: (db, version) async {}),
        throwsStateError);
    final kept = await openDatabase(path,
        version: 2,
        onCreate: (db, version) async {},
        onUpgrade: (db, oldVersion, newVersion) async {});
    addTearDown(kept.close);
    expect(await kept.rawQuery('PRAGMA user_version'), [
      {'user_version': BigInt.two}
    ]);
    expect(await kept.query('note', columns: ['title']), [
      {'title': 'Kept'}
    ]);
  });

  test('version 0 and a refused directory write nothing', () async {
    final missing = '${directory.path}/missing.db';
    await expectLater(
        openDatabase(missing, version: 0, onCreate: (db, version) async {}),
        throwsArgumentError);
    expect(File(missing).existsSync(), isFalse);
    await expectLater(openDatabase(missing, version: 1), throwsArgumentError);
    expect(File(missing).existsSync(), isFalse);
    await expectLater(openDatabase(missing, directoryEntriesDurable: false),
        throwsUnsupportedError);
    expect(File(missing).existsSync(), isFalse);
    expect(File('$missing-journal').existsSync(), isFalse);
  });

  test('a closed database rejects a later insert', () async {
    final db = await openNote('closed.db');
    await db.close();
    await expectLater(db.insert('note', {'title': 'nope'}), throwsStateError);
    expect(db.isOpen, isFalse);
  });
}
