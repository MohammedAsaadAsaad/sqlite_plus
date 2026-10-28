import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'note.dart';

/// ORM notes stored as one database image in [directory].
class NoteStore extends ChangeNotifier {
  NoteStore(this.directory);

  final Directory directory;
  final List<Note> notes = [];
  String search = '';
  bool ready = false;

  MutableSqliteDatabase? _database;
  DbContext? _context;
  DbSet<Note>? _notes;
  Future<void> _gate = Future<void>.value();

  List<Note> get visible {
    final query = search.trim();
    final matched = query.isEmpty
        ? notes
        : notes.where((note) {
            final haystack = '${note.title}\n${note.body}';
            return haystack.contains(query);
          });
    return matched.toList();
  }

  Future<void> open() {
    return _serialized(() async {
      final file = _imageFile();
      final Uint8List? image = file.existsSync() && file.lengthSync() > 0
          ? await file.readAsBytes()
          : null;
      final database = image == null
          ? await MutableSqliteDatabase.create()
          : await MutableSqliteDatabase.fromImage(image);
      final connection = MutableDatabaseConnection(
        database,
        closeDatabase: true,
      );
      final context = DbContext(connection, DbModel([noteType]));
      await context.migrations.ensureCreated();
      _database = database;
      _context = context;
      _notes = context.set(noteType);
      await _reload();
      ready = true;
    });
  }

  Note draft() {
    return Note(
      title: '',
      body: '',
      updated: DateTime.now().toUtc(),
      tint: notes.length % notePapers.length,
    );
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  Future<void> save(Note note) {
    return _serialized(() async {
      final blank = note.title.trim().isEmpty && note.body.trim().isEmpty;
      if (blank && note.id == null) return;
      note.updated = DateTime.now().toUtc();
      if (note.id == null) _notes!.add(note);
      await _context!.saveChanges();
      await _flush();
      await _reload();
    });
  }

  Future<void> togglePin(Note note) {
    return _serialized(() async {
      note.pinned = !note.pinned;
      note.updated = DateTime.now().toUtc();
      await _context!.saveChanges();
      await _flush();
      await _reload();
    });
  }

  Future<void> delete(Note note) {
    return _serialized(() async {
      _notes!.remove(note);
      await _context!.saveChanges();
      await _flush();
      await _reload();
    });
  }

  Future<void> close() {
    return _serialized(() async {
      final context = _context;
      _context = null;
      _notes = null;
      _database = null;
      ready = false;
      notes.clear();
      if (context != null) await context.close();
    });
  }

  Future<void> _reload() async {
    final rows = await _notes!.query.orderBy([
      notePinned.desc(),
      noteUpdated.desc(),
    ]).toList();
    notes
      ..clear()
      ..addAll(rows);
  }

  Future<void> _flush() async {
    final bytes = _database!.exportImage();
    final file = _imageFile();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  File _imageFile() => File('${directory.path}/margin.db');

  Future<void> _serialized(Future<void> Function() action) {
    final result = Completer<void>();
    _gate = _gate.then((_) async {
      try {
        await action();
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future.whenComplete(notifyListeners);
  }
}
