import 'dart:io';
import 'dart:math';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

/// Times indexed and unindexed point queries. The size is the only dataset
/// this process measures. Pass `--size 1000`.
Future<void> main(List<String> arguments) async {
  var size = 1000;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--size' && i + 1 < arguments.length) {
      size = int.parse(arguments[i + 1]);
    }
  }
  final random = Random(20261104);
  final points = [
    for (var i = 0; i < size; i++)
      GeoPoint.xy(random.nextDouble() * 1000, random.nextDouble() * 1000),
  ];
  final query = GeoPolygon(
    exteriorRing: [
      GeoCoordinate(0, 0),
      GeoCoordinate(50, 0),
      GeoCoordinate(50, 50),
      GeoCoordinate(0, 50),
      GeoCoordinate(0, 0),
    ],
  );
  final indexed = await _time('indexed', points, query, spatialIndex: true);
  final plain = await _time('unindexed', points, query, spatialIndex: false);
  final report = {
    'dart': Platform.version,
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'executable': Platform.resolvedExecutable,
    'rss_bytes': ProcessInfo.currentRss,
    'size': size,
    'iterations': 5,
    'sizes_not_run': [10000, 100000, 1000000],
    'indexed': indexed,
    'unindexed': plain,
  };
  final directory = Directory('benchmark/results');
  await directory.create(recursive: true);
  final file = File('benchmark/results/linux_x64_$size.json');
  await file.writeAsString('${_json(report)}\n');
  stdout.writeln(file.path);
  stdout.writeln(_json(report));
}

Future<Map<String, Object>> _time(
  String label,
  List<GeoPoint> points,
  GeoPolygon query, {
  required bool spatialIndex,
}) async {
  final database = await MutableSqliteDatabase.create();
  final geo = GeoSession(database);
  await geo.createSpatialTable(
    'points_$label',
    geometryColumn: 'location',
    geometryType: GeoGeometryType.point,
    columns: const ['name TEXT'],
    spatialIndex: spatialIndex,
  );
  final insert = Stopwatch()..start();
  await database.execute('BEGIN');
  for (var i = 0; i < points.length; i++) {
    await geo.insert(
      'points_$label',
      geometryColumn: 'location',
      geometry: points[i],
      values: {'name': 'p$i'},
    );
  }
  await database.execute('COMMIT');
  insert.stop();
  final samples = <int>[];
  var returned = 0;
  var candidates = 0;
  for (var i = 0; i < 5; i++) {
    final watch = Stopwatch()..start();
    final found = await geo.search(
      'points_$label',
      geometryColumn: 'location',
      geometry: query,
    );
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
    returned = found.rows.length;
    candidates = found.plan.candidates;
  }
  samples.sort();
  return {
    'insert_microseconds': insert.elapsedMicroseconds,
    'query_microseconds': samples,
    'median_microseconds': samples[samples.length ~/ 2],
    'max_microseconds': samples.last,
    'returned': returned,
    'candidates': candidates,
    'used_index': spatialIndex,
  };
}

String _json(Object? value) {
  if (value is Map) {
    return '{${value.entries.map((entry) => '"${entry.key}": ${_json(entry.value)}').join(', ')}}';
  }
  if (value is List) return '[${value.map(_json).join(', ')}]';
  if (value is String) return '"${value.replaceAll('"', r'\"')}"';
  return '$value';
}
