import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'note.dart';

const maxRandomNotes = 10000;

const _words = <String>[
  'هامش',
  'ورقة',
  'حبر',
  'حديقة',
  'دفتر',
  'سطر',
  'ظل',
  'نافذة',
  'مكتب',
  'قلم',
];

class InsertMeasurement {
  const InsertMeasurement({
    required this.image,
    required this.inserted,
    required this.singleTransaction,
    required this.elapsedMicros,
    required this.cpuMicros,
    required this.rssBefore,
    required this.rssPeak,
    required this.rssAfter,
  });

  final Uint8List image;
  final int inserted;
  final bool singleTransaction;
  final int elapsedMicros;
  final int cpuMicros;
  final int rssBefore;
  final int rssPeak;
  final int rssAfter;

  Map<String, Object?> toMessage() => {
    'image': image,
    'inserted': inserted,
    'singleTransaction': singleTransaction,
    'elapsedMicros': elapsedMicros,
    'cpuMicros': cpuMicros,
    'rssBefore': rssBefore,
    'rssPeak': rssPeak,
    'rssAfter': rssAfter,
  };

  static InsertMeasurement fromMessage(Map<dynamic, dynamic> message) {
    return InsertMeasurement(
      image: message['image']! as Uint8List,
      inserted: message['inserted']! as int,
      singleTransaction: message['singleTransaction']! as bool,
      elapsedMicros: message['elapsedMicros']! as int,
      cpuMicros: message['cpuMicros']! as int,
      rssBefore: message['rssBefore']! as int,
      rssPeak: message['rssPeak']! as int,
      rssAfter: message['rssAfter']! as int,
    );
  }
}

class ImageStats {
  const ImageStats({
    required this.pageCount,
    required this.pageSize,
    required this.freelistCount,
    required this.imageBytes,
    required this.noteCount,
  });

  final int pageCount;
  final int pageSize;
  final int freelistCount;
  final int imageBytes;
  final BigInt noteCount;

  int get freelistBytes => freelistCount * pageSize;

  Map<String, Object?> toMessage() => {
    'pageCount': pageCount,
    'pageSize': pageSize,
    'freelistCount': freelistCount,
    'imageBytes': imageBytes,
    'noteCount': noteCount.toString(),
  };

  static ImageStats fromMessage(Map<dynamic, dynamic> message) {
    return ImageStats(
      pageCount: message['pageCount']! as int,
      pageSize: message['pageSize']! as int,
      freelistCount: message['freelistCount']! as int,
      imageBytes: message['imageBytes']! as int,
      noteCount: BigInt.parse(message['noteCount']! as String),
    );
  }
}

class VacuumMeasurement {
  const VacuumMeasurement({
    required this.image,
    required this.before,
    required this.after,
  });

  final Uint8List image;
  final ImageStats before;
  final ImageStats after;

  Map<String, Object?> toMessage() => {
    'image': image,
    'before': before.toMessage(),
    'after': after.toMessage(),
  };

  static VacuumMeasurement fromMessage(Map<dynamic, dynamic> message) {
    return VacuumMeasurement(
      image: message['image']! as Uint8List,
      before: ImageStats.fromMessage(message['before']! as Map),
      after: ImageStats.fromMessage(message['after']! as Map),
    );
  }
}

Future<InsertMeasurement> insertRandomNotes(
  Uint8List image,
  int count, {
  required bool singleTransaction,
  void Function(int done, int total)? onProgress,
}) async {
  if (count < 1 || count > maxRandomNotes) {
    throw ArgumentError.value(count, 'count', 'Use 1 to $maxRandomNotes notes');
  }
  final session = await _Session.open(image);
  final random = Random();
  final clock = Stopwatch()..start();
  final cpuStart = _cpuTicks();
  final rssBefore = _rss();
  var rssPeak = rssBefore;
  final sampler = Timer.periodic(const Duration(milliseconds: 40), (_) {
    final current = _rss();
    if (current > rssPeak) rssPeak = current;
  });
  var inserted = 0;
  try {
    if (singleTransaction) {
      for (var i = 0; i < count; i++) {
        session.notes.add(_randomNote(random, i));
        if (i % 25 == 0) onProgress?.call(i, count);
      }
      inserted = await session.context.saveChanges();
      onProgress?.call(count, count);
    } else {
      for (var i = 0; i < count; i++) {
        session.notes.add(_randomNote(random, i));
        inserted += await session.context.saveChanges();
        onProgress?.call(i + 1, count);
        if (i + 1 < count) await session.reopen();
      }
    }
  } finally {
    sampler.cancel();
    clock.stop();
  }
  final rssAfter = _rss();
  if (rssAfter > rssPeak) rssPeak = rssAfter;
  final bytes = await session.finish();
  final cpuDelta = _cpuTicks() - cpuStart;
  return InsertMeasurement(
    image: bytes,
    inserted: inserted,
    singleTransaction: singleTransaction,
    elapsedMicros: clock.elapsedMicroseconds,
    cpuMicros: cpuDelta <= 0 ? 0 : (cpuDelta * 1000000) ~/ 100,
    rssBefore: rssBefore,
    rssPeak: rssPeak,
    rssAfter: rssAfter,
  );
}

Future<Uint8List> deleteAllNotes(Uint8List image) async {
  final session = await _Session.open(image);
  final rows = await session.notes.query.toList();
  for (final row in rows) {
    session.notes.remove(row);
  }
  await session.context.saveChanges();
  return session.finish();
}

Future<VacuumMeasurement> vacuumNotes(Uint8List image) async {
  final session = await _Session.open(image);
  final before = await _capture(session);
  await session.context.connection.execute('VACUUM');
  final after = await _capture(session);
  final bytes = await session.finish();
  return VacuumMeasurement(image: bytes, before: before, after: after);
}

Future<void> insertNotesIsolate(List<Object?> message) async {
  final send = message[0]! as SendPort;
  try {
    final report = await insertRandomNotes(
      message[1]! as Uint8List,
      message[2]! as int,
      singleTransaction: message[3]! as bool,
      onProgress: (done, total) {
        send.send(<Object?>['progress', done, total]);
      },
    );
    send.send(<Object?>['done', report.toMessage()]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

Future<void> deleteNotesIsolate(List<Object?> message) async {
  final send = message[0]! as SendPort;
  try {
    final image = await deleteAllNotes(message[1]! as Uint8List);
    send.send(<Object?>['done', image]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

Future<void> vacuumNotesIsolate(List<Object?> message) async {
  final send = message[0]! as SendPort;
  try {
    final report = await vacuumNotes(message[1]! as Uint8List);
    send.send(<Object?>['done', report.toMessage()]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

Note _randomNote(Random random, int index) {
  final body = List<String>.generate(
    6,
    (_) => _words[random.nextInt(_words.length)],
  ).join(' ');
  return Note(
    title: 'عشوائية ${index + 1}',
    body: body,
    pinned: random.nextInt(12) == 0,
    updated: DateTime.now().toUtc().subtract(
      Duration(seconds: random.nextInt(3600)),
    ),
    tint: random.nextInt(notePapers.length),
  );
}

class _Session {
  _Session(this.database, this.connection, this.context, this.notes);

  final MutableSqliteDatabase database;
  MutableDatabaseConnection connection;
  DbContext context;
  DbSet<Note> notes;

  static Future<_Session> open(Uint8List image) async {
    final database = await MutableSqliteDatabase.fromImage(image);
    final connection = MutableDatabaseConnection(
      database,
      closeDatabase: false,
    );
    final context = DbContext(connection, DbModel([noteType]));
    return _Session(database, connection, context, context.set(noteType));
  }

  Future<void> reopen() async {
    await context.close();
    connection = MutableDatabaseConnection(database, closeDatabase: false);
    context = DbContext(connection, DbModel([noteType]));
    notes = context.set(noteType);
  }

  Future<Uint8List> finish() async {
    final bytes = database.exportImage();
    await context.close();
    await database.close();
    return bytes;
  }
}

Future<ImageStats> _capture(_Session session) async {
  final noteCount = await session.notes.query.count();
  return ImageStats(
    pageCount: await _pragma(session, 'page_count'),
    pageSize: await _pragma(session, 'page_size'),
    freelistCount: await _pragma(session, 'freelist_count'),
    imageBytes: session.database.exportImage().length,
    noteCount: noteCount,
  );
}

Future<int> _pragma(_Session session, String name) async {
  final result = await session.context.connection.query('PRAGMA $name');
  final value = result.rows.single.single;
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  throw StateError('PRAGMA $name returned $value');
}

int _rss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}

int _cpuTicks() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final end = stat.lastIndexOf(')');
    if (end < 0) return 0;
    final parts = stat.substring(end + 2).split(' ');
    if (parts.length < 13) return 0;
    return int.parse(parts[11]) + int.parse(parts[12]);
  } catch (_) {
    return 0;
  }
}
