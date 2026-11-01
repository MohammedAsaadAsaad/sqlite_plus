/// CSV notes and the day counts drawn by the notes plot.
///
/// This file does not import Flutter or the database engine.
library;

final class ExchangeNote {
  const ExchangeNote({
    this.id,
    required this.title,
    required this.body,
    required this.pinned,
    required this.updated,
    required this.tint,
  });

  final String? id;
  final String title;
  final String body;
  final bool pinned;
  final DateTime updated;
  final int tint;
}

final class PlotBar {
  const PlotBar(this.label, this.value);

  final String label;
  final int value;
}

const csvHeader = 'id,title,body,pinned,updated,tint';

/// Writes [notes] as CSV. Fields that contain a comma, quote, or line break
/// are quoted, and a quote inside a field is doubled.
String exportNotesCsv(Iterable<ExchangeNote> notes) {
  final lines = <String>[csvHeader];
  for (final note in notes) {
    lines.add([
      _cell(note.id ?? ''),
      _cell(note.title),
      _cell(note.body),
      note.pinned ? '1' : '0',
      _cell(note.updated.toUtc().toIso8601String()),
      '${note.tint}',
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}

/// Reads CSV written by [exportNotesCsv]. Imported ids are returned as text
/// and are not treated as database keys.
List<ExchangeNote> importNotesCsv(String csv) {
  final rows = _rows(csv);
  if (rows.isEmpty) {
    throw const FormatException('CSV file is empty');
  }
  if (rows.first.join(',') != csvHeader) {
    throw const FormatException('CSV header must be $csvHeader');
  }
  final notes = <ExchangeNote>[];
  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length == 1 && row.single.isEmpty) continue;
    if (row.length != 6) {
      throw FormatException('CSV row ${i + 1} has ${row.length} columns');
    }
    final pinned = row[3];
    if (pinned != '0' && pinned != '1') {
      throw FormatException('CSV row ${i + 1} has a pinned value of $pinned');
    }
    final updated = DateTime.tryParse(row[4]);
    if (updated == null) {
      throw FormatException('CSV row ${i + 1} has an unreadable time');
    }
    final tint = int.tryParse(row[5]);
    if (tint == null) {
      throw FormatException('CSV row ${i + 1} has an unreadable tint');
    }
    notes.add(ExchangeNote(
      id: row[0].isEmpty ? null : row[0],
      title: row[1],
      body: row[2],
      pinned: pinned == '1',
      updated: updated.toUtc(),
      tint: tint,
    ));
  }
  return notes;
}

/// One bar per UTC day, in calendar order. An empty input has no bars.
List<PlotBar> notesByUpdatedDay(Iterable<ExchangeNote> notes) {
  final counts = <String, int>{};
  for (final note in notes) {
    final day = note.updated.toUtc().toIso8601String().substring(0, 10);
    counts[day] = (counts[day] ?? 0) + 1;
  }
  final days = counts.keys.toList()..sort();
  return [for (final day in days) PlotBar(day, counts[day]!)];
}

String _cell(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

List<List<String>> _rows(String csv) {
  final rows = <List<String>>[];
  final row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var i = 0;
  void finishCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void finishRow() {
    if (row.isEmpty && cell.isEmpty) return;
    finishCell();
    rows.add(List<String>.of(row));
    row.clear();
  }

  while (i < csv.length) {
    final char = csv[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < csv.length && csv[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        quoted = false;
        i++;
        continue;
      }
      cell.write(char);
      i++;
      continue;
    }
    if (char == '"' && cell.isEmpty) {
      quoted = true;
      i++;
      continue;
    }
    if (char == ',') {
      finishCell();
      i++;
      continue;
    }
    if (char == '\n') {
      finishRow();
      i++;
      continue;
    }
    if (char == '\r') {
      i++;
      continue;
    }
    cell.write(char);
    i++;
  }
  if (quoted) throw const FormatException('CSV quote is not closed');
  if (cell.isNotEmpty || row.isNotEmpty) finishRow();
  return rows;
}
