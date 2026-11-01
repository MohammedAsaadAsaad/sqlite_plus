import 'dart:typed_data';

import 'tokenizer.dart';

/// Web and other non-IO runtimes have no destination file to publish.
Future<void> publishVacuumInto(String path, Uint8List bytes,
    {required bool crashBeforeRename}) async {
  if (path.isEmpty && bytes.isEmpty && !crashBeforeRename) {
    throw const SqlException('VACUUM INTO is unavailable');
  }
  throw const SqlException('VACUUM INTO is unavailable');
}
