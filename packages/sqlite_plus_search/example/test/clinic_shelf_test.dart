import 'package:sqlite_plus_search_example/clinic_shelf.dart';
import 'package:test/test.dart';

void main() {
  test('the clinic shelf shows folding, a filter, and a later insert',
      () async {
    final shelf = await runClinicShelf();
    expect(shelf.pharmacyMilk, ['1']);
    expect(shelf.everyMilkNote, containsAll(['1', '3']));
    expect(shelf.everyMilkNote, isNot(contains('2')));
    expect(shelf.teaAddedLater, '4');
    expect(shelf.stemmedGarden, ['1']);
    expect(shelf.hybrid.first.id, '1');
    expect(shelf.hybrid.first.keywordRank, 1);
    expect(shelf.hybrid.first.vectorRank, 1);
    expect(shelf.hybrid.map((hit) => hit.id), contains('2'));
    expect(shelf.unknownFixtureRejected, isTrue);
  });
}
