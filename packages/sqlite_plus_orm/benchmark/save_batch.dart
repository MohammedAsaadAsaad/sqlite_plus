import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// Highest row count this tool will measure.
const saveBatchRowCeiling = 10000;

/// One `saveChanges` of many added rows, after `ensureCreated`.
///
/// Rows above [saveBatchRowCeiling] throw. The package tests do not call this.
Future<Map<String, Object?>> measureSaveBatch({
  int samples = 3,
  List<int> sizes = const [1000, 10000],
}) async {
  if (samples < 1) {
    throw ArgumentError.value(samples, 'samples', 'at least one sample');
  }
  if (sizes.isEmpty ||
      sizes.any((size) => size < 1 || size > saveBatchRowCeiling)) {
    throw ArgumentError.value(sizes, 'sizes',
        'each size must be from 1 through $saveBatchRowCeiling');
  }
  final measured = <Map<String, Object?>>[];
  for (final rows in sizes) {
    final ensured = <int>[];
    final tracked = <int>[];
    final saved = <int>[];
    final images = <int>[];
    for (var sample = 0; sample < samples; sample++) {
      final connection = await MutableDatabaseConnection.openMemory();
      final context = DbContext(connection, DbModel([_noteType]));
      try {
        ensured.add(await _elapsed(() => context.migrations.ensureCreated()));
        final notes = [
          for (var index = 0; index < rows; index++)
            _Note(
              'note $index',
              'body $index',
              index % 12 == 0,
              DateTime.utc(2026, 10, 28, 4, index % 60, index % 60),
              index % 4,
            )
        ];
        final set = context.set(_noteType);
        tracked.add(await _elapsed(() async {
          for (final note in notes) {
            set.add(note);
          }
        }));
        saved.add(await _elapsed(() async {
          final changed = await context.saveChanges();
          if (changed != rows) throw StateError('save count differs');
          if (notes.any((note) => note.id == null)) {
            throw StateError('generated key was not published');
          }
        }));
        images.add(connection.database.exportImage().length);
      } finally {
        await context.close();
      }
    }
    measured.add({
      'rows': rows,
      'ensure_created': _timed(ensured),
      'track': _timed(tracked, rowsTouched: rows),
      'save': _timed(saved, rowsTouched: rows),
      'image_bytes': images,
    });
  }
  return {
    'workload':
        'Generated-key notes with title, body, pinned, updated, and tint. Each sample calls ensureCreated, tracks every note, then one saveChanges. A fresh memory database is used for every sample.',
    'row_ceiling': saveBatchRowCeiling,
    'samples': samples,
    'sizes': sizes,
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
        'Linux x64 only when the AOT executable is run there. This is not macOS, Windows, Android, or iOS, and it is not a native SQLite comparison. RSS is the whole process. The earlier scenarios_10k_linux_x64.json file is a different workload and is not a delta for these samples.',
  };
}

Future<void> main(List<String> args) async {
  String? output;
  for (final arg in args) {
    const prefix = '--output=';
    if (arg.startsWith(prefix)) output = arg.substring(prefix.length);
  }
  final payload = await measureSaveBatch();
  final text = jsonEncode(payload);
  if (output != null) File(output).writeAsStringSync('$text\n');
  stdout.writeln(text);
}

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
