import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

import '../test/rollback_pager_test.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Expected output directory');
  final original = originalImage();
  // A commit is the journal write and its sync. crashAt 2 runs the sync,
  // which persists the redo, then throws before any database write.
  final faults = CrashController()..crashAt = 2;
  final database = ModelFile(original, faults);
  final journal = ModelFile(Uint8List(0), faults);
  final pager = await RollbackJournalPager.open(database, journal);
  try {
    await pager.commitImage(updatedImage(original, 99));
    throw StateError('Expected simulated crash');
  } on SimulatedCrash {
    await File('${args.single}/snapshot.db').writeAsBytes(database.durable);
    await File('${args.single}/snapshot.db-journal')
        .writeAsBytes(journal.durable);
  }
}
