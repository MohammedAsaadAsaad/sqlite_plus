import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  test('Web Mercator moves the coordinate and SetSRID does not', () {
    final point = GeoPoint(longitude: 1, latitude: 0, srid: 4326);
    final tagged = point.withSrid(3857);
    expect(tagged.position!.x, 1);
    expect(tagged.position!.y, 0);
    final projected = geoTransform(point, targetSrid: 3857) as GeoPoint;
    expect(projected.srid, 3857);
    expect(projected.position!.x, closeTo(111319.49079327357, 1e-6));
    expect(projected.position!.y, closeTo(0, 1e-6));
    final back = geoTransform(projected, targetSrid: 4326) as GeoPoint;
    expect(back.position!.x, closeTo(1, 1e-8));
    expect(back.position!.y, closeTo(0, 1e-8));
  });

  test('UTM zone 36 places longitude 33 on the central meridian', () {
    final point = GeoPoint(longitude: 33, latitude: 0, srid: 4326);
    expect(geoCrs(32636).projection['centralMeridian'], 33);
    final projected = geoTransform(point, targetSrid: 32636) as GeoPoint;
    expect(projected.position!.x, closeTo(500000, 1e-4));
    expect(projected.position!.y, closeTo(0, 1e-2));
    final back = geoTransform(projected, targetSrid: 4326) as GeoPoint;
    expect(back.position!.x, closeTo(33, 1e-6));
    expect(back.position!.y, closeTo(0, 1e-6));
    final south = geoTransform(
      GeoPoint(longitude: 33, latitude: -1, srid: 4326),
      targetSrid: 32736,
    ) as GeoPoint;
    expect(south.position!.y, lessThan(10000000));
    expect(south.position!.y, greaterThan(9000000));
  });

  test('a high latitude and an unknown datum are reported', () {
    expect(
      () => geoTransform(
        GeoPoint(longitude: 0, latitude: 89, srid: 4326),
        targetSrid: 3857,
      ),
      throwsA(isA<GeoException>()),
    );
    expect(() => geoCrs(27700), throwsA(isA<GeoException>()));
    expect(
      () => geoTransform(GeoPoint.xy(1, 2), targetSrid: 4326),
      throwsA(isA<GeoException>()),
    );
    expect(geoCrs(4326).geographic, isTrue);
    expect(geoCrs(3857).units, 'metre');
  });
}
