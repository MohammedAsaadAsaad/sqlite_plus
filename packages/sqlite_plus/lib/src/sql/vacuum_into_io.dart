import 'dart:io';
import 'dart:typed_data';

import 'tokenizer.dart';
import 'vacuum_into_crash.dart';

/// Publishes [bytes] at [path]. An existing non-empty file is rejected. A
/// crash stops after the temporary file is flushed, so [path] is never a
/// partial database.
Future<void> publishVacuumInto(String path, Uint8List bytes,
    {required bool crashBeforeRename}) async {
  if (path.isEmpty) {
    if (crashBeforeRename) throw const VacuumIntoCrash();
    return;
  }
  final dest = File(path);
  if (dest.existsSync()) {
    final stat = dest.statSync();
    if (stat.type != FileSystemEntityType.file) {
      throw SqlException('unable to open database: $path');
    }
    if (stat.size > 0) {
      throw const SqlException('output file already exists');
    }
  } else {
    final parent = dest.parent;
    if (!parent.existsSync() ||
        FileSystemEntity.typeSync(parent.path) !=
            FileSystemEntityType.directory) {
      throw SqlException('unable to open database: $path');
    }
  }
  final temp = File('$path-vacuuminto');
  await temp.writeAsBytes(bytes, flush: true);
  if (crashBeforeRename) throw const VacuumIntoCrash();
  try {
    await temp.rename(path);
  } on FileSystemException {
    throw SqlException('unable to open database: $path');
  }
}
