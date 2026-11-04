import 'dart:convert';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

/// The four examples share one in-memory database.
final class GeoDemos {
  /// [nearestName] is the closest facility. [zoneName] contains the sample
  /// point. [imported] is the GeoJSON row count. [intersectionArea] is the
  /// overlap of the two analytic squares.
  const GeoDemos({
    required this.nearestName,
    required this.zoneName,
    required this.imported,
    required this.intersectionArea,
    required this.indexed,
  });

  /// Facility returned by the geographic nearest query.
  final String nearestName;

  /// Administrative polygon that contains the sample point.
  final String zoneName;

  /// Features imported from the embedded GeoJSON document.
  final int imported;

  /// Planar area of the intersection, in CRS units.
  final double intersectionArea;

  /// Whether the point-in-polygon query used the R-tree.
  final bool indexed;
}

GeoPolygon _ring(List<(double, double)> points, {int srid = 0}) => GeoPolygon(
      exteriorRing: [
        for (final point in points) GeoCoordinate(point.$1, point.$2),
        GeoCoordinate(points.first.$1, points.first.$2),
      ],
      srid: srid,
    );

/// Nearby facilities, an offline GeoJSON query, a boundary lookup, and one
/// spatial join. Each one writes rows through sqlite_plus.
Future<GeoDemos> runGeoDemos() async {
  final database = await MutableSqliteDatabase.create();
  final geo = GeoSession(database);
  try {
    final nearestName = await _facilities(geo);
    final imported = await _fieldNotes(geo, database);
    final zone = await _zones(geo);
    final analytics = await _analytics(database);
    return GeoDemos(
      nearestName: nearestName,
      zoneName: zone.$1,
      imported: imported,
      intersectionArea: analytics,
      indexed: zone.$2,
    );
  } finally {
    // The memory database has no file to close.
  }
}

Future<String> _facilities(GeoSession geo) async {
  await geo.createSpatialTable(
    'facilities',
    geometryColumn: 'location',
    geometryType: GeoGeometryType.point,
    srid: 4326,
  );
  await geo.insert(
    'facilities',
    geometryColumn: 'location',
    geometry: GeoPoint(longitude: 34.30, latitude: 31.35, srid: 4326),
    values: {'name': 'Clinic'},
  );
  await geo.insert(
    'facilities',
    geometryColumn: 'location',
    geometry: GeoPoint(longitude: 34.45, latitude: 31.50, srid: 4326),
    values: {'name': 'Depot'},
  );
  final nearest = await geo.nearest(
    'facilities',
    geometryColumn: 'location',
    point: GeoPoint(longitude: 34.31, latitude: 31.36, srid: 4326),
    limit: 1,
    maxDistance: 5000,
    metric: GeodesicModel.sphere,
  );
  final rowid = nearest.rows.single.hit.rowid;
  final name = await geo.database.query(
    'SELECT name FROM facilities WHERE rowid = ?',
    [rowid],
  );
  return name.rows.single.single! as String;
}

Future<int> _fieldNotes(GeoSession geo, MutableSqliteDatabase database) async {
  await geo.createSpatialTable(
    'notes',
    geometryColumn: 'geometry',
    geometryType: GeoGeometryType.point,
    srid: 4326,
  );
  const document = '''
{"type":"FeatureCollection","features":[
  {"type":"Feature","geometry":{"type":"Point","coordinates":[34.30,31.35]},"properties":{"name":"Well"}},
  {"type":"Feature","geometry":{"type":"Point","coordinates":[34.32,31.36]},"properties":{"name":"Gate"}}
]}''';
  final progress = await geo.importGeoJsonStream(
    bytes: Stream.value(utf8.encode(document)),
    table: 'notes',
    geometryColumn: 'geometry',
    batchSize: 1000,
  );
  final inside = await geo.search(
    'notes',
    geometryColumn: 'geometry',
    geometry: _ring(const [
      (34.29, 31.34),
      (34.33, 31.34),
      (34.33, 31.37),
      (34.29, 31.37),
    ], srid: 4326),
  );
  if (inside.rows.length != 2 || !inside.plan.usedIndex) {
    throw StateError(inside.plan.describe());
  }
  final mapPoint = (inside.rows.first.geometry as GeoPoint).toMapPosition();
  if (mapPoint.longitude != 34.30 && mapPoint.longitude != 34.32) {
    throw StateError('map longitude was swapped');
  }
  final count = await database.query('SELECT count(*) FROM notes');
  if (count.rows.single.single != BigInt.from(progress.accepted)) {
    throw StateError('import count drifted');
  }
  return progress.accepted;
}

Future<(String, bool)> _zones(GeoSession geo) async {
  await geo.createSpatialTable(
    'zones',
    geometryColumn: 'geometry',
    geometryType: GeoGeometryType.polygon,
    srid: 4326,
  );
  await geo.insert(
    'zones',
    geometryColumn: 'geometry',
    geometry: _ring(const [
      (34.2, 31.2),
      (34.4, 31.2),
      (34.4, 31.5),
      (34.2, 31.5),
    ], srid: 4326),
    values: {'name': 'North'},
  );
  await geo.insert(
    'zones',
    geometryColumn: 'geometry',
    geometry: _ring(const [
      (35.0, 31.2),
      (35.2, 31.2),
      (35.2, 31.4),
      (35.0, 31.4),
    ], srid: 4326),
    values: {'name': 'East'},
  );
  final found = await geo.search(
    'zones',
    geometryColumn: 'geometry',
    geometry: GeoPoint(longitude: 34.30, latitude: 31.35, srid: 4326),
    predicate: SpatialPredicate.contains,
  );
  final rowid = found.rows.single.rowid;
  final name = await geo.database.query(
    'SELECT name FROM zones WHERE rowid = ?',
    [rowid],
  );
  return (name.rows.single.single! as String, found.plan.usedIndex);
}

Future<double> _analytics(MutableSqliteDatabase database) async {
  SqlitePlusGeo.register(database);
  await database.execute(
    'CREATE TABLE parcels (id INTEGER PRIMARY KEY, name TEXT, geometry BLOB)',
  );
  final west = _ring(const [
    (0, 0),
    (2, 0),
    (2, 2),
    (0, 2),
  ]);
  final east = _ring(const [
    (1, 0),
    (3, 0),
    (3, 2),
    (1, 2),
  ]);
  await database.execute(
    'INSERT INTO parcels(name, geometry) VALUES (?, ?), (?, ?)',
    ['West', west.toEwkb(), 'East', east.toEwkb()],
  );
  final area = await database.query('''
    SELECT ST_Area(ST_Intersection(a.geometry, b.geometry))
    FROM parcels a
    JOIN parcels b ON a.name = 'West' AND b.name = 'East'
  ''');
  final value = area.rows.single.single;
  if (value is! double) throw StateError('intersection area was $value');
  return value;
}
