import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// One tracked note. The application names fields. The ORM writes the SQL.
final class Note {
  Note({
    this.id,
    required this.title,
    required this.body,
    this.pinned = false,
    required this.updated,
    this.tint = 0,
  });

  BigInt? id;
  String title;
  String body;
  bool pinned;
  DateTime updated;
  int tint;
}

final noteId = Column<Note, BigInt?>(
  property: 'id',
  codec: Codecs.nullable(Codecs.bigInt),
  read: (note) => note.id,
  write: (note, value) => note.id = value,
  keyOrder: 0,
  generated: true,
);

final noteTitle = Column<Note, String>(
  property: 'title',
  codec: Codecs.text,
  read: (note) => note.title,
  write: (note, value) => note.title = value,
);

final noteBody = Column<Note, String>(
  property: 'body',
  codec: Codecs.text,
  read: (note) => note.body,
  write: (note, value) => note.body = value,
);

final notePinned = Column<Note, bool>(
  property: 'pinned',
  codec: Codecs.boolean,
  read: (note) => note.pinned,
  write: (note, value) => note.pinned = value,
);

final noteUpdated = Column<Note, DateTime>(
  property: 'updated',
  codec: Codecs.dateTime,
  read: (note) => note.updated,
  write: (note, value) => note.updated = value,
);

final noteTint = Column<Note, int>(
  property: 'tint',
  codec: Codecs.integer,
  read: (note) => note.tint,
  write: (note, value) => note.tint = value,
);

final noteType = EntityType<Note>(
  tableName: 'notes',
  columns: [noteId, noteTitle, noteBody, notePinned, noteUpdated, noteTint],
  create: (row) => Note(
    id: row.read(noteId),
    title: row.read(noteTitle),
    body: row.read(noteBody),
    pinned: row.read(notePinned),
    updated: row.read(noteUpdated),
    tint: row.read(noteTint),
  ),
  applyStoreValues: (note, row) {
    note.id = row.read(noteId);
    note.title = row.read(noteTitle);
    note.body = row.read(noteBody);
    note.pinned = row.read(notePinned);
    note.updated = row.read(noteUpdated);
    note.tint = row.read(noteTint);
    return note;
  },
);

const notePapers = <int, int>{
  0: 0xFFF4E7D4,
  1: 0xFFF3D2C8,
  2: 0xFFD7E4D4,
  3: 0xFFD5E2F2,
};

int paperForTint(int tint) => notePapers[tint] ?? notePapers[0]!;

int paperOf(Note note) => paperForTint(note.tint);
