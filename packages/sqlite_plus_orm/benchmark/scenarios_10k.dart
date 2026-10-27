import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// Highest row count this tool will measure. Larger sizes are rejected.
const scenarioRowCeiling = 10000;

/// Sizes from the earlier ladder that this invocation does not run.
const scenarioSizesNotRun = [100000, 1000000];

/// Measures the 10,000-row scenarios. [rows] above [scenarioRowCeiling] throws.
///
/// [includeFile] opens a pre-created rollback-journal file. The package test
/// leaves it false. The published AOT run sets it true.
Future<Map<String, Object?>> measureScenarios({
  int rows = scenarioRowCeiling,
  int samples = 3,
  bool includeFile = true,
}) async {
  if (rows < 1 || rows > scenarioRowCeiling) {
    throw ArgumentError.value(
        rows, 'rows', 'row count must be from 1 through $scenarioRowCeiling');
  }
  if (samples < 1) {
    throw ArgumentError.value(samples, 'samples', 'at least one sample');
  }
  final insert = _insertSql(rows);
  final point = rows == 1 ? 1 : rows;
  final rangeEnd = rows == 1 ? 1 : rows ~/ 2;
  final memorySql = await _memorySql(
      rows: rows,
      samples: samples,
      insert: insert,
      point: point,
      rangeEnd: rangeEnd);
  final memoryOrm = await _memoryOrm(
      rows: rows, samples: samples, point: point, rangeEnd: rangeEnd);
  final fileSql = includeFile
      ? await _fileSql(
          rows: rows, samples: samples, insert: insert, point: point)
      : <String, Object?>{
          'ran': false,
          'reason':
              'includeFile was false. The published AOT run sets includeFile true.',
        };
  return {
    'workload':
        'One row count at or below $scenarioRowCeiling. Memory SQL and memory ORM measure insert, point cold, point warm, range cold, range warm, one update, and one delete. File SQL, when included, repeats the SQL insert and the point query on a pre-created rollback-journal file. Each sample uses a fresh database.',
    'row_ceiling': scenarioRowCeiling,
    'rows': rows,
    'samples': samples,
    'sizes_not_run': scenarioSizesNotRun,
    'sizes_not_run_reason':
        'The requested ceiling is $scenarioRowCeiling rows. 100000 and 1000000 were not run.',
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'hostname': Platform.localHostname,
    'runtime': 'AOT executable',
    'cold_definition':
        'The first measured SQL query after the fill, in the same process. It is not a new process. Image export and file length are taken before that query and are not the cold sample.',
    'warm_definition':
        'The next repetition of that same SQL query in that process.',
    'population_variance_definition':
        'The integer floor of the population variance of the microsecond samples: sum((sample - mean)^2) / sample_count.',
    'rows_per_second_definition':
        '(rows_touched * 1000000) ~/ microseconds. Omitted when rows_touched is 0.',
    'memory_sql': memorySql,
    'memory_orm': memoryOrm,
    'file_sql': fileSql,
    'peak_process_rss_bytes': ProcessInfo.maxRss,
    'limitations':
        'Linux x64 only when the AOT executable is run there. This is not macOS, Windows, Android, or iOS, and it is not a native SQLite comparison. 100000 and 1000000 rows were not run. The ORM image includes the _sqlite_plus_orm_model catalog after ensureCreated, so its byte length differs from the raw SQL image. directoryEntriesDurable true on the temp file is a caller attestation, not a power-loss result. RSS is the whole process. No earlier binary was measured, so no delta is claimed.',
  };
}

Future<void> main(List<String> args) async {
  String? output;
  for (final arg in args) {
    const prefix = '--output=';
    if (arg.startsWith(prefix)) output = arg.substring(prefix.length);
  }
  final payload = await measureScenarios();
  final text = jsonEncode(payload);
  if (output != null) File(output).writeAsStringSync('$text\n');
  stdout.writeln(text);
}

final class _Note {
  _Note(this.id, this.name);
  final BigInt id;
  String name;
}

final _noteId = Column<_Note, BigInt>(
    property: 'id',
    name: 'id',
    codec: Codecs.bigInt,
    read: (note) => note.id,
    keyOrder: 0);
final _noteName = Column<_Note, String>(
    property: 'name',
    name: 'name',
    codec: Codecs.text,
    read: (note) => note.name);
final _noteType = EntityType<_Note>(
    tableName: 'notes',
    columns: [_noteId, _noteName],
    create: (row) => _Note(row.read(_noteId), row.read(_noteName)));

const _createNotes =
    'CREATE TABLE "notes" ("id" INTEGER NOT NULL PRIMARY KEY, "name" TEXT NOT NULL)';

String _insertSql(int rows) {
  final buffer = StringBuffer('INSERT INTO "notes"("id","name") VALUES ');
  for (var id = 1; id <= rows; id++) {
    if (id > 1) buffer.write(',');
    buffer.write("($id,'n')");
  }
  final sql = buffer.toString();
  if (sql.length > 1024 * 1024) {
    throw StateError('INSERT exceeds the 1 MiB SQL limit');
  }
  return sql;
}

int _populationVariance(List<int> samples) {
  final count = samples.length;
  final total = samples.fold<int>(0, (sum, sample) => sum + sample);
  var sumSquares = 0;
  for (final sample in samples) {
    sumSquares += sample * sample;
  }
  return (count * sumSquares - total * total) ~/ (count * count);
}

Map<String, Object?> _timed(List<int> samples, {required int rowsTouched}) {
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

Future<Map<String, Object?>> _memorySql({
  required int rows,
  required int samples,
  required String insert,
  required int point,
  required int rangeEnd,
}) async {
  final create = <int>[];
  final inserted = <int>[];
  final pointCold = <int>[];
  final pointWarm = <int>[];
  final rangeCold = <int>[];
  final rangeWarm = <int>[];
  final updated = <int>[];
  final deleted = <int>[];
  final images = <int>[];
  for (var sample = 0; sample < samples; sample++) {
    final db = await MutableSqliteDatabase.create();
    try {
      create.add(await _elapsed(() => db.execute(_createNotes)));
      inserted.add(await _elapsed(() => db.execute(insert)));
      images.add(db.exportImage().length);
      pointCold.add(await _elapsed(() => _sqlPoint(db, point)));
      pointWarm.add(await _elapsed(() => _sqlPoint(db, point)));
      rangeCold.add(await _elapsed(() => _sqlRange(db, rangeEnd)));
      rangeWarm.add(await _elapsed(() => _sqlRange(db, rangeEnd)));
      updated.add(await _elapsed(() => _sqlUpdate(db, point)));
      deleted.add(await _elapsed(() => _sqlDelete(db, point)));
    } finally {
      await db.close();
    }
  }
  return {
    'create_table': _timed(create, rowsTouched: 0),
    'insert': _timed(inserted, rowsTouched: rows),
    'point_cold': _timed(pointCold, rowsTouched: 1),
    'point_warm': _timed(pointWarm, rowsTouched: 1),
    'range_cold': _timed(rangeCold, rowsTouched: rangeEnd),
    'range_warm': _timed(rangeWarm, rowsTouched: rangeEnd),
    'update': _timed(updated, rowsTouched: 1),
    'delete': _timed(deleted, rowsTouched: 1),
    'image_bytes': images,
  };
}

Future<void> _sqlPoint(MutableSqliteDatabase db, int point) async {
  final result = await db.query(
      'SELECT "id","name" FROM "notes" WHERE "id"=?', [BigInt.from(point)]);
  final row = result.rows.single;
  if (row[0] != BigInt.from(point) || row[1] != 'n') {
    throw StateError('SQL point row differs');
  }
}

Future<void> _sqlRange(MutableSqliteDatabase db, int rangeEnd) async {
  final result = await db.query(
      'SELECT COUNT(*) FROM "notes" WHERE "id">=? AND "id"<=?',
      [BigInt.one, BigInt.from(rangeEnd)]);
  if (result.rows.single.single != BigInt.from(rangeEnd)) {
    throw StateError('SQL range count differs');
  }
}

Future<void> _sqlUpdate(MutableSqliteDatabase db, int point) async {
  final result = await db.execute(
      'UPDATE "notes" SET "name"=? WHERE "id"=?', ['u', BigInt.from(point)]);
  if (result.changes != 1) throw StateError('SQL update count differs');
}

Future<void> _sqlDelete(MutableSqliteDatabase db, int point) async {
  final result = await db
      .execute('DELETE FROM "notes" WHERE "id"=?', [BigInt.from(point)]);
  if (result.changes != 1) throw StateError('SQL delete count differs');
}

Future<Map<String, Object?>> _memoryOrm({
  required int rows,
  required int samples,
  required int point,
  required int rangeEnd,
}) async {
  final ensured = <int>[];
  final tracked = <int>[];
  final saved = <int>[];
  final pointCold = <int>[];
  final pointWarm = <int>[];
  final rangeCold = <int>[];
  final rangeWarm = <int>[];
  final updated = <int>[];
  final deleted = <int>[];
  final images = <int>[];
  final pointKey = BigInt.from(point);
  final rangeKey = BigInt.from(rangeEnd);
  for (var sample = 0; sample < samples; sample++) {
    final connection = await MutableDatabaseConnection.openMemory();
    final context = DbContext(connection, DbModel([_noteType]));
    try {
      ensured.add(await _elapsed(() => context.migrations.ensureCreated()));
      final notes = [
        for (var id = 1; id <= rows; id++) _Note(BigInt.from(id), 'n')
      ];
      final set = context.set(_noteType);
      tracked.add(await _elapsed(() async {
        for (final note in notes) {
          set.add(note);
        }
      }));
      saved.add(await _elapsed(() async {
        final changed = await context.saveChanges();
        if (changed != rows) throw StateError('ORM insert count differs');
      }));
      images.add(connection.database.exportImage().length);
      pointCold.add(await _elapsed(() => _ormPoint(set, pointKey)));
      pointWarm.add(await _elapsed(() => _ormPoint(set, pointKey)));
      rangeCold.add(await _elapsed(() => _ormRange(set, rangeKey)));
      rangeWarm.add(await _elapsed(() => _ormRange(set, rangeKey)));
      final target = notes[point - 1];
      target.name = 'u';
      updated.add(await _elapsed(() async {
        final changed = await context.saveChanges();
        if (changed != 1) throw StateError('ORM update count differs');
      }));
      set.remove(target);
      deleted.add(await _elapsed(() async {
        final changed = await context.saveChanges();
        if (changed != 1) throw StateError('ORM delete count differs');
      }));
    } finally {
      await context.close();
    }
  }
  return {
    'ensure_created': _timed(ensured, rowsTouched: 0),
    'track': _timed(tracked, rowsTouched: rows),
    'save': _timed(saved, rowsTouched: rows),
    'point_cold': _timed(pointCold, rowsTouched: 1),
    'point_warm': _timed(pointWarm, rowsTouched: 1),
    'range_cold': _timed(rangeCold, rowsTouched: rangeEnd),
    'range_warm': _timed(rangeWarm, rowsTouched: rangeEnd),
    'update': _timed(updated, rowsTouched: 1),
    'delete': _timed(deleted, rowsTouched: 1),
    'image_bytes': images,
  };
}

Future<void> _ormPoint(DbSet<_Note> set, BigInt point) async {
  final found =
      await set.query.where(_noteId.eq(point)).asNoTracking().single();
  if (found.id != point || found.name != 'n') {
    throw StateError('ORM point row differs');
  }
}

Future<void> _ormRange(DbSet<_Note> set, BigInt rangeEnd) async {
  final count = await set.query
      .where(_noteId.gte(BigInt.one) & _noteId.lte(rangeEnd))
      .asNoTracking()
      .count();
  if (count != rangeEnd) throw StateError('ORM range count differs');
}

Future<Map<String, Object?>> _fileSql({
  required int rows,
  required int samples,
  required String insert,
  required int point,
}) async {
  final opened = <int>[];
  final create = <int>[];
  final inserted = <int>[];
  final pointCold = <int>[];
  final pointWarm = <int>[];
  final files = <int>[];
  final journals = <int>[];
  for (var sample = 0; sample < samples; sample++) {
    final directory =
        Directory.systemTemp.createTempSync('sqlite-plus-scenarios-');
    final path = '${directory.path}/data.db';
    final seed = await MutableSqliteDatabase.create();
    File(path).writeAsBytesSync(seed.exportImage());
    await seed.close();
    File('$path-journal').writeAsBytesSync(const []);
    DatabaseOwner? owner;
    try {
      owner = await _openOwner(path, opened);
      final client = owner.client;
      create.add(await _elapsed(() => client.execute(_createNotes)));
      inserted.add(await _elapsed(() => client.execute(insert)));
      files.add(File(path).lengthSync());
      journals.add(File('$path-journal').lengthSync());
      pointCold.add(await _elapsed(() => _filePoint(client, point)));
      pointWarm.add(await _elapsed(() => _filePoint(client, point)));
    } finally {
      await owner?.close();
      await _deleteDirectory(directory);
    }
  }
  return {
    'ran': true,
    'open': _timed(opened, rowsTouched: 0),
    'create_table': _timed(create, rowsTouched: 0),
    'insert': _timed(inserted, rowsTouched: rows),
    'point_cold': _timed(pointCold, rowsTouched: 1),
    'point_warm': _timed(pointWarm, rowsTouched: 1),
    'file_bytes': files,
    'journal_bytes': journals,
    'durability':
        'directoryEntriesDurable true is a caller attestation on a temp file. Power loss was not measured.',
  };
}

Future<DatabaseOwner> _openOwner(String path, List<int> opened) async {
  final watch = Stopwatch()..start();
  final owner = await DatabaseOwner.open(path, directoryEntriesDurable: true);
  watch.stop();
  final microseconds = watch.elapsedMicroseconds;
  if (microseconds <= 0) {
    await owner.close();
    throw StateError('file open elapsed $microseconds microseconds');
  }
  opened.add(microseconds);
  return owner;
}

Future<void> _filePoint(DatabaseClient client, int point) async {
  final result = await client.query(
      'SELECT "id","name" FROM "notes" WHERE "id"=?', [BigInt.from(point)]);
  final row = result.rows.single;
  if (row[0] != BigInt.from(point) || row[1] != 'n') {
    throw StateError('file point row differs');
  }
}

Future<void> _deleteDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      return;
    } on PathAccessException {
      if (attempt == 19) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
