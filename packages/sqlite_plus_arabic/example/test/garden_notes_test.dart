import 'package:sqlite_plus_arabic_example/garden_notes.dart';
import 'package:test/test.dart';

void main() {
  test('search finds the stemmed garden and misses the car', () async {
    final notes = await runGardenNotes();
    expect(notes.found, 'في الحديقة');
    expect(notes.missed, isTrue);
    expect(notes.secondPlanEmpty, isTrue);
  });
}
