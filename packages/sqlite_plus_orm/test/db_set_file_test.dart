import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Note {
  _Note(this.id, this.body);
  final BigInt id;
  String body;
}

final _id = Column<_Note, BigInt>(
  property: 'id',
  codec: Codecs.bigInt,
  read: (note) => note.id,
  keyOrder: 0,
);
final _body = Column<_Note, String>(
  property: 'body',
  codec: Codecs.text,
  read: (note) => note.body,
  write: (note, value) => note.body = value,
);
final _type = EntityType<_Note>(
  tableName: 'notes',
  columns: [_id, _body],
  create: (row) => _Note(row.read(_id), row.read(_body)),
);

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-orm-file-');
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

  test('open creates the file, and a later open keeps the row', () async {
    final path = '${directory.path}/nested/notes.db';
    final notes = await DbSet.openDbFile(_type, path);
    notes.add(_Note(BigInt.one, 'kept'));
    expect(await notes.saveChanges(), 1);
    expect(notes.context.connection.inTransaction, isFalse);
    await notes.close();
    expect(File(path).existsSync(), isTrue);
    expect(await File('$path-journal').length(), 0);

    final reopened = await DbSet.openDbFile(_type, path);
    final stored = await reopened.query.where(_body.eq('kept')).single();
    expect(stored.body, 'kept');
    expect((await reopened.migrations.plan()).isEmpty, isTrue);
    await reopened.close();
    expect(reopened.saveChanges(), throwsA(isA<OrmStateException>()));
  });

  test('open adds an empty journal beside an existing database file', () async {
    final path = '${directory.path}/existing.db';
    final created = await MutableSqliteDatabase.create();
    try {
      await created.execute(
          'CREATE TABLE "notes" ("id" INTEGER NOT NULL PRIMARY KEY, "body" TEXT NOT NULL)');
      await created.execute(
          'INSERT INTO "notes" ("id", "body") VALUES (1, \'already\')');
      await File(path).writeAsBytes(created.exportImage(), flush: true);
    } finally {
      await created.close();
    }
    expect(File('$path-journal').existsSync(), isFalse);
    final notes = await DbSet.openDbFile(_type, path);
    final stored = await notes.query.where(_body.eq('already')).single();
    expect(stored.body, 'already');
    await notes.close();
    expect(await File('$path-journal').length(), 0);
  });

  test('open closes the file when creating the table fails', () async {
    final path = '${directory.path}/bad.db';
    final body = Column<_Note, String>(
      property: 'body',
      codec: Codecs.text,
      read: (note) => note.body,
      write: (note, value) => note.body = value,
      defaultSql: 'not valid',
    );
    await expectLater(
      DbSet.openDbFile(
        EntityType<_Note>(
          tableName: 'notes',
          columns: [_id, body],
          create: (row) => _Note(row.read(_id), row.read(body)),
        ),
        path,
      ),
      throwsA(isA<Exception>()),
    );
    final notes = await DbSet.openDbFile(_type, path);
    notes.add(_Note(BigInt.one, 'kept'));
    expect(await notes.saveChanges(), 1);
    await notes.close();
  });

  test('refusing the durability attestation writes no file', () async {
    final path = '${directory.path}/skipped.db';
    await expectLater(
      DbSet.openDbFile(_type, path, directoryEntriesDurable: false),
      throwsA(isA<UnsupportedError>()),
    );
    expect(File(path).existsSync(), isFalse);
    expect(File('$path-journal').existsSync(), isFalse);
  });
}
