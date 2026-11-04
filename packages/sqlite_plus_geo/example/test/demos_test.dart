import 'package:sqlite_plus_geo_example/demos.dart';
import 'package:test/test.dart';

void main() {
  test('four spatial examples use the database', () async {
    final demos = await runGeoDemos();
    expect(demos.nearestName, 'Clinic');
    expect(demos.zoneName, 'North');
    expect(demos.imported, 2);
    expect(demos.intersectionArea, closeTo(2, 1e-6));
    expect(demos.indexed, isTrue);
  });
}
