import '../lib/note_exchange.dart';

void main() {
  final first = ExchangeNote(
    id: '7',
    title: 'Margin, "ink"',
    body: 'line one\nline two',
    pinned: true,
    updated: DateTime.utc(2026, 11, 1, 8, 30),
    tint: 2,
  );
  final second = ExchangeNote(
    title: 'Plain',
    body: '',
    pinned: false,
    updated: DateTime.utc(2026, 11, 1, 21),
    tint: 0,
  );
  final third = ExchangeNote(
    title: 'Next',
    body: 'x',
    pinned: false,
    updated: DateTime.utc(2026, 11, 2, 1),
    tint: 4,
  );
  final csv = exportNotesCsv([first, second, third]);
  final parsed = importNotesCsv(csv);
  if (parsed.length != 3) {
    throw StateError('expected 3 notes, got ${parsed.length}');
  }
  if (parsed[0].id != '7' ||
      parsed[0].title != 'Margin, "ink"' ||
      parsed[0].body != 'line one\nline two' ||
      parsed[0].pinned != true ||
      parsed[0].updated != DateTime.utc(2026, 11, 1, 8, 30) ||
      parsed[0].tint != 2) {
    throw StateError('first note changed: ${parsed[0].title}');
  }
  if (parsed[1].id != null || parsed[1].pinned || parsed[1].body.isNotEmpty) {
    throw StateError('second note changed');
  }
  final bars = notesByUpdatedDay(parsed);
  if (bars.length != 2 ||
      bars[0].label != '2026-11-01' ||
      bars[0].value != 2 ||
      bars[1].label != '2026-11-02' ||
      bars[1].value != 1) {
    throw StateError('bars $bars');
  }
  if (notesByUpdatedDay(const []).isNotEmpty) {
    throw StateError('empty input produced bars');
  }
  _expectFormat(() => importNotesCsv(''), 'CSV file is empty');
  _expectFormat(
    () => importNotesCsv('title,body\n'),
    'CSV header must be $csvHeader',
  );
  _expectFormat(
    () => importNotesCsv('$csvHeader\n1,a,b,2,2026-11-01T00:00:00.000Z,0\n'),
    'pinned value of 2',
  );
  _expectFormat(
      () => importNotesCsv('$csvHeader\n"open\n'), 'quote is not closed');
  print('note exchange checks passed');
}

void _expectFormat(void Function() body, String fragment) {
  try {
    body();
  } on FormatException catch (error) {
    if (!error.message.contains(fragment)) {
      throw StateError('expected "$fragment" in "${error.message}"');
    }
    return;
  }
  throw StateError('expected FormatException containing $fragment');
}
