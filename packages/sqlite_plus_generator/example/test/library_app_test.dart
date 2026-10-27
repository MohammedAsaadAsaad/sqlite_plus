import 'package:test/test.dart';

import 'package:sqlite_plus_generator_example/library_app.dart';

void main() {
  test(
      'the generated library filters purchases and reads JSON, FTS, and R-tree',
      () async {
    final library = await runLibraryApp();
    expect(library.customer, 'Ada');
    expect(library.totals, [22.5, 30.0]);
    expect(library.matchCount, BigInt.two);
    expect(library.note, '{"title":"kept"}');
    expect(library.article, 'alpha kept');
    expect(library.placeId, BigInt.one);
    expect(library.insideCount, 1);
    expect(library.storedPlaces, 2);
    expect(library.secondPlanEmpty, isTrue);
  });
}
