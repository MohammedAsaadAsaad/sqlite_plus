import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'note.dart';
import 'note_work.dart';

/// ORM notes stored as one database image in [directory].
class NoteStore extends ChangeNotifier {
  NoteStore(this.directory);

  final Directory directory;
  final List<Note> notes = [];
  String search = '';
  bool ready = false;
  bool busy = false;
  int progressDone = 0;
  int progressTotal = 0;
  String progressLabel = '';
  InsertMeasurement? lastInsert;
  VacuumMeasurement? lastVacuum;

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
      _checkIdle();
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
      _checkIdle();
      note.pinned = !note.pinned;
      note.updated = DateTime.now().toUtc();
      await _context!.saveChanges();
      await _flush();
      await _reload();
    });
  }

  Future<InsertMeasurement> insertRandom(
    int count, {
    required bool singleTransaction,
  }) {
    return _serializedValue(() async {
      _checkIdle();
      busy = true;
      progressDone = 0;
      progressTotal = count;
      progressLabel = singleTransaction ? 'معاملة واحدة' : 'حفظ منفصل';
      notifyListeners();
      try {
        final image = _database!.exportImage();
        final report = InsertMeasurement.fromMessage(
          await _isolate(
            insertNotesIsolate,
            <Object?>[image, count, singleTransaction],
            onProgress: (done, total) {
              progressDone = done;
              progressTotal = total;
              notifyListeners();
            },
          ),
        );
        await _replaceImage(report.image);
        lastInsert = report;
        return report;
      } finally {
        busy = false;
        progressLabel = '';
      }
    });
  }

  Future<void> deleteAll() {
    return _serialized(() async {
      _checkIdle();
      busy = true;
      progressLabel = 'مسح الكل';
      notifyListeners();
      try {
        final image = await _isolateBytes(deleteNotesIsolate, <Object?>[
          _database!.exportImage(),
        ]);
        await _replaceImage(image);
        lastInsert = null;
      } finally {
        busy = false;
        progressLabel = '';
      }
    });
  }

  Future<VacuumMeasurement> vacuum() {
    return _serializedValue(() async {
      _checkIdle();
      busy = true;
      progressLabel = 'VACUUM';
      notifyListeners();
      try {
        final report = VacuumMeasurement.fromMessage(
          await _isolate(vacuumNotesIsolate, <Object?>[
            _database!.exportImage(),
          ]),
        );
        await _replaceImage(report.image);
        lastVacuum = report;
        return report;
      } finally {
        busy = false;
        progressLabel = '';
      }
    });
  }

  Future<DatabaseSnapshot> details() {
    return _serializedValue(() async {
      _checkIdle();
      final master = await _context!.connection.query(
        'SELECT type, name FROM sqlite_master ORDER BY name',
      );
      final file = _imageFile();
      final noteCount = await _notes!.query.count();
      return DatabaseSnapshot(
        path: file.path,
        fileBytes: file.existsSync() ? file.lengthSync() : 0,
        imageBytes: _database!.exportImage().length,
        pageCount: await _pragma('page_count'),
        pageSize: await _pragma('page_size'),
        freelistCount: await _pragma('freelist_count'),
        noteCount: noteCount,
        objects: [
          for (final row in master.rows) SchemaObject('${row[0]}', '${row[1]}'),
        ],
        notes: List<Note>.of(notes),
      );
    });
  }

  Future<void> delete(Note note) {
    return _serialized(() async {
      _checkIdle();
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

  void _checkIdle() {
    if (busy) throw StateError('عمل آخر قيد التنفيذ');
  }

  Future<void> _replaceImage(Uint8List image) async {
    final database = await MutableSqliteDatabase.fromImage(image);
    final connection = MutableDatabaseConnection(database, closeDatabase: true);
    final context = DbContext(connection, DbModel([noteType]));
    final previous = _context;
    _database = database;
    _context = context;
    _notes = context.set(noteType);
    if (previous != null) await previous.close();
    await _flush();
    await _reload();
  }

  Future<int> _pragma(String name) async {
    final result = await _context!.connection.query('PRAGMA $name');
    final value = result.rows.single.single;
    if (value is BigInt) return value.toInt();
    if (value is int) return value;
    throw StateError('PRAGMA $name returned $value');
  }

  Future<Map<dynamic, dynamic>> _isolate(
    Future<void> Function(List<Object?> message) entry,
    List<Object?> arguments, {
    void Function(int done, int total)? onProgress,
  }) {
    final receive = ReceivePort();
    final result = Completer<Map<dynamic, dynamic>>();
    final subscription = receive.listen((message) {
      final list = message as List<Object?>;
      switch (list[0]) {
        case 'progress':
          onProgress?.call(list[1]! as int, list[2]! as int);
        case 'done':
          if (!result.isCompleted) {
            result.complete(Map<dynamic, dynamic>.from(list[1]! as Map));
          }
          receive.close();
        case 'error':
          if (!result.isCompleted) {
            result.completeError(StateError('${list[1]}'));
          }
          receive.close();
      }
    });
    Isolate.spawn<List<Object?>>(entry, <Object?>[
      receive.sendPort,
      ...arguments,
    ]).then<void>(
      (isolate) {},
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future.whenComplete(subscription.cancel);
  }

  Future<Uint8List> _isolateBytes(
    Future<void> Function(List<Object?> message) entry,
    List<Object?> arguments,
  ) async {
    final receive = ReceivePort();
    final result = Completer<Uint8List>();
    final subscription = receive.listen((message) {
      final list = message as List<Object?>;
      switch (list[0]) {
        case 'done':
          if (!result.isCompleted) result.complete(list[1]! as Uint8List);
          receive.close();
        case 'error':
          if (!result.isCompleted) {
            result.completeError(StateError('${list[1]}'));
          }
          receive.close();
      }
    });
    Isolate.spawn<List<Object?>>(entry, <Object?>[
      receive.sendPort,
      ...arguments,
    ]).then<void>(
      (isolate) {},
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future.whenComplete(subscription.cancel);
  }

  Future<void> _serialized(Future<void> Function() action) {
    return _serializedValue(action);
  }

  Future<T> _serializedValue<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _gate = _gate.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future.whenComplete(notifyListeners);
  }
}

class SchemaObject {
  const SchemaObject(this.type, this.name);

  final String type;
  final String name;
}

class DatabaseSnapshot {
  const DatabaseSnapshot({
    required this.path,
    required this.fileBytes,
    required this.imageBytes,
    required this.pageCount,
    required this.pageSize,
    required this.freelistCount,
    required this.noteCount,
    required this.objects,
    required this.notes,
  });

  final String path;
  final int fileBytes;
  final int imageBytes;
  final int pageCount;
  final int pageSize;
  final int freelistCount;
  final BigInt noteCount;
  final List<SchemaObject> objects;
  final List<Note> notes;

  int get freelistBytes => freelistCount * pageSize;
}
