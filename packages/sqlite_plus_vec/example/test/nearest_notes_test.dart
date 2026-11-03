import 'package:sqlite_plus_vec_example/nearest_notes.dart';
import 'package:test/test.dart';

void main() {
  test('nearest returns the vector closer to the query', () async {
    final notes = await runNearestNotes();
    expect(notes.first, greaterThan(0.5));
    expect(notes.secondPlanEmpty, isTrue);
  });
}
