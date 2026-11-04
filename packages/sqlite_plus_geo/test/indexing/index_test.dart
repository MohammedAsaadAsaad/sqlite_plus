import 'dart:math';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

Future<GeoSession> _open() async {
  final database = await MutableSqliteDatabase.create();
  final geo = GeoSession(database);
  await geo.createSpatialTable(
    'places',
    geometryColumn: 'location',
    geometryType: GeoGeometryType.point,
    srid: 0,
  );
  return geo;
}

void main() {
  test('indexed search matches a full scan and keeps float32 boxes', () async {
    final geo = await _open();
    final random = Random(20261104);
    final points = <GeoPoint>[
      for (var i = 0; i < 200; i++)
        GeoPoint.xy(random.nextDouble() * 100, random.nextDouble() * 100),
      GeoPoint.xy(0.1, 0.1),
    ];
    for (final point in points) {
      await geo.insert('places', geometryColumn: 'location', geometry: point);
    }
    final query = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(10, 0),
        GeoCoordinate(10, 10),
        GeoCoordinate(0, 10),
        GeoCoordinate(0, 0),
      ],
    );
    final indexed = await geo.search(
      'places',
      geometryColumn: 'location',
      geometry: query,
    );
    expect(indexed.plan.usedIndex, isTrue);
    expect(indexed.plan.describe(), contains('spatial index'));
    final brute = [
      for (final point in points)
        if (geoIntersects(point, query)) point,
    ];
    expect(indexed.rows, hasLength(brute.length));
    expect(indexed.rows.map((hit) => hit.geometry),
        contains(GeoPoint.xy(0.1, 0.1)));
  });

  test('rollback, reopen, delete, and rebuild keep the index honest', () async {
    final geo = await _open();
    await geo.database.execute('BEGIN');
    await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(1, 1),
    );
    await geo.database.execute('ROLLBACK');
    expect(
        (await geo.validateIndex('places', geometryColumn: 'location'))
            .consistent,
        isTrue);
    final count = await geo.database.query('SELECT count(*) FROM places');
    expect(count.rows.single.single, BigInt.zero);

    final kept = await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(4, 5),
      values: {'name': 'Kept'},
    );
    final other = await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(8, 9),
      values: {'name': 'Other'},
    );
    await geo.updateGeometry(
      'places',
      rowid: other,
      geometryColumn: 'location',
      geometry: GeoPoint.xy(6, 6),
    );
    await geo.delete('places', rowid: other, geometryColumn: 'location');
    final image = geo.database.exportImage();
    final reopened = GeoSession(await MutableSqliteDatabase.fromImage(image));
    final found = await reopened.search(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(4, 5),
    );
    expect(found.rows.single.rowid, kept);

    final info = await reopened.database.query(
      "SELECT spatial_index FROM geo_spatial_columns WHERE table_name = 'places'",
    );
    final index = info.rows.single.single! as String;
    await reopened.database.execute('DELETE FROM $index WHERE id = ?', [kept]);
    final broken =
        await reopened.validateIndex('places', geometryColumn: 'location');
    expect(broken.missing, [kept]);
    expect(broken.consistent, isFalse);
    await reopened.rebuildIndex('places', geometryColumn: 'location');
    expect(
      (await reopened.validateIndex('places', geometryColumn: 'location'))
          .consistent,
      isTrue,
    );
  });

  test('nearest orders by distance then rowid and a join uses the index',
      () async {
    final geo = await _open();
    await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(10, 0),
      values: {'name': 'Far'},
    );
    final second = await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(1, 0),
      values: {'name': 'TieB'},
    );
    final first = await geo.insert(
      'places',
      geometryColumn: 'location',
      geometry: GeoPoint.xy(1, 0),
      values: {'name': 'TieA'},
    );
    final nearest = await geo.nearest(
      'places',
      geometryColumn: 'location',
      point: GeoPoint.xy(0, 0),
      limit: 2,
    );
    expect(nearest.rows.map((row) => row.hit.rowid),
        [first < second ? first : second, first < second ? second : first]);
    expect(nearest.rows.first.distance, 1);
    expect(nearest.plan.usedIndex, isTrue);

    await geo.createSpatialTable(
      'zones',
      geometryColumn: 'geometry',
      geometryType: GeoGeometryType.polygon,
    );
    await geo.insert(
      'zones',
      geometryColumn: 'geometry',
      geometry: GeoPolygon(
        exteriorRing: [
          GeoCoordinate(0, 0),
          GeoCoordinate(3, 0),
          GeoCoordinate(3, 3),
          GeoCoordinate(0, 3),
          GeoCoordinate(0, 0),
        ],
      ),
      values: {'name': 'Near'},
    );
    final joined = await geo.join(
      leftTable: 'places',
      leftColumn: 'location',
      rightTable: 'zones',
      rightColumn: 'geometry',
      predicate: SpatialPredicate.intersects,
    );
    expect(joined.rows, hasLength(2));
    expect(joined.plan.usedIndex, isTrue);
  });
}
