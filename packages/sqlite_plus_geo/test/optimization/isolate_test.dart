import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  test('an isolate returns the same hull as the calling isolate', () async {
    final points = GeoMultiPoint([
      GeoPoint.xy(0, 0),
      GeoPoint.xy(2, 0),
      GeoPoint.xy(1, 1),
      GeoPoint.xy(1, 0.2),
    ]);
    final isolated = await geoComputeIsolated(
      points,
      operation: GeoIsolateOperation.convexHull,
    );
    expect(isolated, geoConvexHull(points));
  });
}
