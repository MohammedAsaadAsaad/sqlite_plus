import 'dart:io';

import 'package:sqlite_plus_vec_example/nearest_notes.dart';

Future<void> main() async {
  final notes = await runNearestNotes();
  stdout.writeln(
    '${notes.first} | stable ${notes.secondPlanEmpty}',
  );
}
