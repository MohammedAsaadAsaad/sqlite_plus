import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// One Arabic full-text search. `الحديقة` and `حديقة` share a token.
final class GardenNotes {
  const GardenNotes({
    required this.found,
    required this.missed,
    required this.secondPlanEmpty,
  });

  /// Body of the note found by `search('الحديقة')`.
  final String found;

  /// Whether `search('كتاب')` returned no row.
  final bool missed;

  /// Whether a second migration plan is empty.
  final bool secondPlanEmpty;
}

final class Note {
  Note({this.rowid, required this.body});

  BigInt? rowid;
  String body;
}

final _rowid = Column<Note, BigInt?>(
  property: 'rowid',
  codec: Codecs.nullable(Codecs.bigInt),
  read: (note) => note.rowid,
  write: (note, value) => note.rowid = value,
  keyOrder: 0,
  generated: true,
);
final _body = Column<Note, String>(
  property: 'body',
  codec: Codecs.text,
  read: (note) => note.body,
  write: (note, value) => note.body = value,
);
final _type = EntityType<Note>(
  tableName: 'notes',
  columns: [_rowid, _body],
  virtualModule: DbModules.fts5,
  tokenizer: ArabicTokenizers.arabic,
  create: (row) => Note(rowid: row.read(_rowid), body: row.read(_body)),
);

/// Registers the Arabic tokenizer, saves two notes, and searches one word.
Future<GardenNotes> runGardenNotes() async {
  final dir = await Directory.systemTemp.createTemp('garden_notes_');
  final path = '${dir.path}/garden.db';
  final database = await MutableSqliteDatabase.create();
  SqlitePlusArabic.register(database);
  final connection = MutableDatabaseConnection(database, closeDatabase: true);
  final context = DbContext(connection, DbModel([_type]));
  late GardenNotes result;
  try {
    await context.migrations.ensureCreated();
    final notes = context.set(_type);
    notes.add(Note(body: 'في الحديقة'));
    notes.add(Note(body: 'كتاب بعيد'));
    if (await context.saveChanges() != 2) {
      throw StateError('insert did not save two notes');
    }
    final found = await notes.query.search('الحديقة').single();
    final missed = await notes.query.search('سيارة').toList();
    await File(path).writeAsBytes(database.exportImage(), flush: true);
    result = GardenNotes(
      found: found.body,
      missed: missed.isEmpty,
      secondPlanEmpty: (await context.migrations.plan()).isEmpty,
    );
  } finally {
    await context.close();
  }
  final again =
      await MutableSqliteDatabase.fromImage(await File(path).readAsBytes());
  try {
    SqlitePlusArabic.register(again);
    final rows = await again.query(
      "SELECT body FROM notes WHERE notes MATCH 'الحديقة'",
    );
    if (rows.rows.single.single != result.found) {
      throw StateError('garden.db lost the note');
    }
  } finally {
    await again.close();
  }
  return result;
}
