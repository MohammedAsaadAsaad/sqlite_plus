import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// Highest row count this tool will measure.
const residentOpsRowCeiling = 10000;

/// Separate saves, one delete, and a batched delete, then one image export.
///
/// Rows above [residentOpsRowCeiling] throw. The package tests do not call this.
Future<Map<String, Object?>> measureResidentOps({
  int samples = 3,
  List<int> separateSizes = const [100, 1000],
  List<int> deleteSizes = const [1000, 10000],
  int deleteOneRows = 1000,
}) async {
  if (samples < 1) {
    throw ArgumentError.value(samples, 'samples', 'at least one sample');
  }
  for (final size in [...separateSizes, ...deleteSizes, deleteOneRows]) {
    if (size < 1 || size > residentOpsRowCeiling) {
      throw ArgumentError.value(
          size, 'rows', 'must be from 1 through $residentOpsRowCeiling');
    }
  }
  final measured = <Map<String, Object?>>[];
  for (final rows in separateSizes) {
    final saves = <int>[];
    final exports = <int>[];
    final images = <int>[];
    for (var sample = 0; sample < samples; sample++) {
      final database = await MutableSqliteDatabase.create();
      var connection =
          MutableDatabaseConnection(database, closeDatabase: false);
      var context = DbContext(connection, DbModel([_noteType]));
      try {
        await context.migrations.ensureCreated();
        saves.add(await _elapsed(() async {
          for (var index = 0; index < rows; index++) {
            context.set(_noteType).add(_note(index));
            final changed = await context.saveChanges();
            if (changed != 1) throw StateError('separate save count differs');
            await context.close();
            if (index + 1 == rows) break;
            connection =
                MutableDatabaseConnection(database, closeDatabase: false);
            context = DbContext(connection, DbModel([_noteType]));
          }
        }));
        final image = _elapsedImage(database);
        exports.add(image.$1);
        images.add(image.$2);
        connection = MutableDatabaseConnection(database, closeDatabase: false);
        context = DbContext(connection, DbModel([_noteType]));
        final stored = await context.set(_noteType).query.count();
        if (stored != BigInt.from(rows)) {
          throw StateError('separate row count differs');
        }
      } finally {
        await context.close();
        await database.close();
      }
    }
    measured.add({
      'name': 'separate_saves',
      'rows': rows,
      'saves': _timed(saves, rowsTouched: rows),
      'export': _timed(exports),
      'image_bytes': images,
    });
  }
  final oneDeletes = <int>[];
  final oneExports = <int>[];
  final oneImages = <int>[];
  for (var sample = 0; sample < samples; sample++) {
    final database = await MutableSqliteDatabase.create();
    final connection =
        MutableDatabaseConnection(database, closeDatabase: false);
    final context = DbContext(connection, DbModel([_noteType]));
    try {
      await context.migrations.ensureCreated();
      final set = context.set(_noteType);
      for (var index = 0; index < deleteOneRows; index++) {
        set.add(_note(index));
      }
      final seeded = await context.saveChanges();
      if (seeded != deleteOneRows) throw StateError('seed count differs');
      final stored = await set.query.toList();
      set.remove(stored.first);
      oneDeletes.add(await _elapsed(() async {
        final changed = await context.saveChanges();
        if (changed != 1) throw StateError('delete count differs');
      }));
      final image = _elapsedImage(database);
      oneExports.add(image.$1);
      oneImages.add(image.$2);
      if (await set.query.count() != BigInt.from(deleteOneRows - 1)) {
        throw StateError('remaining row count differs');
      }
    } finally {
      await context.close();
      await database.close();
    }
  }
  measured.add({
    'name': 'delete_one',
    'rows': deleteOneRows,
    'save': _timed(oneDeletes, rowsTouched: 1),
    'export': _timed(oneExports),
    'image_bytes': oneImages,
  });
  for (final rows in deleteSizes) {
    final saves = <int>[];
    final exports = <int>[];
    final images = <int>[];
    for (var sample = 0; sample < samples; sample++) {
      final database = await MutableSqliteDatabase.create();
      final connection =
          MutableDatabaseConnection(database, closeDatabase: false);
      final context = DbContext(connection, DbModel([_noteType]));
      try {
        await context.migrations.ensureCreated();
        final set = context.set(_noteType);
        for (var index = 0; index < rows; index++) {
          set.add(_note(index));
        }
        final seeded = await context.saveChanges();
        if (seeded != rows) throw StateError('seed count differs');
        final stored = await set.query.toList();
        for (final note in stored) {
          set.remove(note);
        }
        saves.add(await _elapsed(() async {
          final changed = await context.saveChanges();
          if (changed != rows) throw StateError('delete-all count differs');
        }));
        final image = _elapsedImage(database);
        exports.add(image.$1);
        images.add(image.$2);
        if (await set.query.count() != BigInt.zero) {
          throw StateError('delete-all left rows');
        }
      } finally {
        await context.close();
        await database.close();
      }
    }
    measured.add({
      'name': 'delete_all',
      'rows': rows,
      'save': _timed(saves, rowsTouched: rows),
      'export': _timed(exports),
      'image_bytes': images,
    });
  }
  return {
    'workload':
        'Generated-key notes with title, body, pinned, updated, and tint. separate_saves calls saveChanges once per note and reopens the context on the same database, then exports the image once. delete_one and delete_all seed with one saveChanges, then time the deleting saveChanges and the following exportImage. A fresh memory database is used for every sample.',
    'row_ceiling': residentOpsRowCeiling,
    'samples': samples,
    'separate_sizes': separateSizes,
    'delete_one_rows': deleteOneRows,
    'delete_sizes': deleteSizes,
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'hostname': Platform.localHostname,
    'runtime': 'AOT executable',
    'rows_per_second_definition':
        '(rows_touched * 1000000) ~/ microseconds. Omitted when rows_touched is 0.',
    'population_variance_definition':
        'The integer floor of the population variance of the microsecond samples: sum((sample - mean)^2) / sample_count.',
    'measurements': measured,
    'peak_process_rss_bytes': ProcessInfo.maxRss,
    'limitations':
        'Linux x64 only when the AOT executable is run there. This is not macOS, Windows, Android, iOS, or a phone, and it is not a native SQLite comparison. RSS is the whole process. orm_save_batch_linux_x64.json and scenarios_10k_linux_x64.json are different workloads and are not deltas for these samples.',
  };
}

Future<void> main(List<String> args) async {
  String? output;
  for (final arg in args) {
    const prefix = '--output=';
    if (arg.startsWith(prefix)) output = arg.substring(prefix.length);
  }
  final payload = await measureResidentOps();
  final text = jsonEncode(payload);
  if (output != null) File(output).writeAsStringSync('$text\n');
  stdout.writeln(text);
}

_Note _note(int index) => _Note(
      'note $index',
      'body $index',
      index % 12 == 0,
      DateTime.utc(2026, 10, 28, 4, index % 60, index % 60),
      index % 4,
    );

final class _Note {
  _Note(this.title, this.body, this.pinned, this.updated, this.tint);
  BigInt? id;
  String title;
  String body;
  bool pinned;
  DateTime updated;
  int tint;
}

final _id = Column<_Note, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (note) => note.id,
    write: (note, value) => note.id = value,
    keyOrder: 0,
    generated: true);
final _title = Column<_Note, String>(
    property: 'title',
    codec: Codecs.text,
    read: (note) => note.title,
    write: (note, value) => note.title = value);
final _body = Column<_Note, String>(
    property: 'body',
    codec: Codecs.text,
    read: (note) => note.body,
    write: (note, value) => note.body = value);
final _pinned = Column<_Note, bool>(
    property: 'pinned',
    codec: Codecs.boolean,
    read: (note) => note.pinned,
    write: (note, value) => note.pinned = value);
final _updated = Column<_Note, DateTime>(
    property: 'updated',
    codec: Codecs.dateTime,
    read: (note) => note.updated,
    write: (note, value) => note.updated = value);
final _tint = Column<_Note, int>(
    property: 'tint',
    codec: Codecs.integer,
    read: (note) => note.tint,
    write: (note, value) => note.tint = value);
final _noteType = EntityType<_Note>(
    tableName: 'notes',
    columns: [_id, _title, _body, _pinned, _updated, _tint],
    create: (row) => _Note(row.read(_title), row.read(_body), row.read(_pinned),
        row.read(_updated), row.read(_tint))
      ..id = row.read(_id));

int _populationVariance(List<int> samples) {
  final count = samples.length;
  final total = samples.fold<int>(0, (sum, sample) => sum + sample);
  var sumSquares = 0;
  for (final sample in samples) {
    sumSquares += sample * sample;
  }
  return (count * sumSquares - total * total) ~/ (count * count);
}

Map<String, Object?> _timed(List<int> samples, {int rowsTouched = 0}) {
  final result = <String, Object?>{
    'microseconds': samples,
    'population_variance': _populationVariance(samples),
    'rows_touched': rowsTouched,
  };
  if (rowsTouched > 0) {
    result['rows_per_second'] = [
      for (final elapsed in samples) (rowsTouched * 1000000) ~/ elapsed
    ];
  }
  return result;
}

Future<int> _elapsed(Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  watch.stop();
  final microseconds = watch.elapsedMicroseconds;
  if (microseconds <= 0) {
    throw StateError('sample elapsed $microseconds microseconds');
  }
  return microseconds;
}

(int, int) _elapsedImage(MutableSqliteDatabase database) {
  final watch = Stopwatch()..start();
  final image = database.exportImage();
  watch.stop();
  final microseconds = watch.elapsedMicroseconds;
  if (microseconds <= 0) {
    throw StateError('export elapsed $microseconds microseconds');
  }
  return (microseconds, image.length);
}
