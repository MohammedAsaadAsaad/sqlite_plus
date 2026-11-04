import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/io.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  test('GeoJSON and CSV streams insert rows and export them again', () async {
    final geo = GeoSession(await MutableSqliteDatabase.create());
    await geo.createSpatialTable(
      'facilities',
      geometryColumn: 'location',
      geometryType: GeoGeometryType.point,
      srid: 4326,
    );
    const document = '''
{"type":"FeatureCollection","features":[
 {"type":"Feature","geometry":{"type":"Point","coordinates":[34.3,31.35]},"properties":{"name":"Clinic"}},
 {"type":"Feature","geometry":null,"properties":{"name":"Missing"}},
 {"type":"Feature","geometry":{"type":"Point","coordinates":[34.4,31.4]},"properties":{"name":"School"}}
]}''';
    final progress = await geo.importGeoJsonStream(
      bytes: Stream.value(utf8.encode(document)),
      table: 'facilities',
      geometryColumn: 'location',
      batchSize: 1,
      skipInvalid: true,
    );
    expect(progress.accepted, 2);
    expect(progress.rejected, 1);
    final sink = StringBuffer();
    await geo.exportGeoJson(
      table: 'facilities',
      geometryColumn: 'location',
      sink: sink,
      propertyColumns: const ['name'],
    );
    final exported = jsonDecode(sink.toString()) as Map<String, Object?>;
    final features = exported['features']! as List<Object?>;
    expect(features, hasLength(2));
    final first = features.first! as Map<String, Object?>;
    final geometry = first['geometry']! as Map<String, Object?>;
    final coordinates = geometry['coordinates']! as List<Object?>;
    expect(coordinates.first, 34.3);
    expect(coordinates[1], 31.35);

    final csv = await geo.importCsvStream(
      bytes: Stream.value(utf8
          .encode('longitude,latitude,name\n34.5,31.5,Depot\nbad,31,Nope\n')),
      table: 'facilities',
      geometryColumn: 'location',
      skipInvalid: true,
    );
    expect(csv.accepted, 1);
    expect(csv.rejected, 1);
    final names =
        await geo.database.query('SELECT name FROM facilities ORDER BY name');
    expect(names.rows.map((row) => row.single), ['Clinic', 'Depot', 'School']);
  });

  test('a cancelled import keeps only the committed batch', () async {
    final geo = GeoSession(await MutableSqliteDatabase.create());
    await geo.createSpatialTable(
      'facilities',
      geometryColumn: 'location',
      geometryType: GeoGeometryType.point,
      srid: 4326,
    );
    final features = [
      for (var i = 0; i < 3; i++)
        '{"type":"Feature","geometry":{"type":"Point","coordinates":[$i,1]},"properties":{"name":"N$i"}}',
    ].join('\n');
    var seen = 0;
    final progress = await geo.importGeoJsonStream(
      bytes: Stream.value(utf8.encode(features)),
      table: 'facilities',
      geometryColumn: 'location',
      batchSize: 1,
      isCancelled: () => seen++ > 0,
    );
    expect(progress.accepted, lessThan(3));
  });

  test('a GeoJSON file replaces the table export', () async {
    final geo = GeoSession(await MutableSqliteDatabase.create());
    await geo.createSpatialTable(
      'facilities',
      geometryColumn: 'geometry',
      geometryType: GeoGeometryType.point,
      srid: 4326,
    );
    final directory = await Directory.systemTemp.createTemp('sqlite_plus_geo');
    try {
      final source = File('${directory.path}/in.geojson');
      await source.writeAsString(
        '{"type":"Feature","geometry":{"type":"Point","coordinates":[34.3,31.35]},"properties":{"name":"Clinic"}}',
      );
      final progress = await geo.importGeoJson(
        filePath: source.path,
        table: 'facilities',
      );
      expect(progress.accepted, 1);
      final target = File('${directory.path}/out.geojson');
      await geo.exportGeoJsonFile(
        filePath: target.path,
        table: 'facilities',
        geometryColumn: 'geometry',
        propertyColumns: const ['name'],
      );
      final exported =
          jsonDecode(await target.readAsString()) as Map<String, Object?>;
      final feature = (exported['features']! as List<Object?>).single!
          as Map<String, Object?>;
      final properties = feature['properties']! as Map<String, Object?>;
      expect(properties['name'], 'Clinic');
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
