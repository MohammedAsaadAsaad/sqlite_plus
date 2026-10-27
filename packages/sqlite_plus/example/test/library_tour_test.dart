import 'package:test/test.dart';

import 'package:sqlite_plus_example/library_tour.dart';

void main() {
  test('the library tour keeps JSON, FTS, R-tree, rollback, and the image',
      () async {
    final tour = await runLibraryTour();
    expect(tour.title, 'Kept Garden');
    expect(tour.pages, BigInt.from(320));
    expect(tour.highlighted, 'a garden [kept] in the margin');
    expect(tour.rank, isA<double>());
    expect(tour.rank.isFinite, isTrue);
    expect(tour.arabicTitle, 'Arabic Shelf');
    expect(tour.arabicMatches, BigInt.one);
    expect(tour.placeId, BigInt.one);
    expect(tour.keptCards, BigInt.two);
    expect(tour.userVersion, BigInt.from(7));
    expect(tour.reopenedTitle, 'Kept Garden');
    expect(tour.reopenedVersion, BigInt.from(7));
    expect(tour.imageBytes, greaterThan(0));
  });
}
