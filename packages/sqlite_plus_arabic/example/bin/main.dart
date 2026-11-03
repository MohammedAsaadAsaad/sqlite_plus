import 'dart:io';

import 'package:sqlite_plus_arabic_example/garden_notes.dart';

Future<void> main() async {
  final notes = await runGardenNotes();
  stdout.writeln(
    '${notes.found} | missed ${notes.missed} | stable ${notes.secondPlanEmpty}',
  );
}
