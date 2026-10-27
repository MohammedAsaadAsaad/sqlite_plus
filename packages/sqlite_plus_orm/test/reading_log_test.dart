import 'package:test/test.dart';

import '../example/reading_log.dart';

void main() {
  test('the reading log tracks one rename and leaves the other book', () async {
    final log = await runReadingLog();
    expect(log.title, 'Kept Garden Revised');
    expect(log.shelf, 'north');
    expect(log.revision, 1);
    expect(log.otherTitle, 'Other Atlas');
    expect(log.otherRevision, 0);
    expect(log.keptCount, BigInt.one);
    expect(log.idleSave, 0);
    expect(log.secondPlanEmpty, isTrue);
  });
}
