import 'dart:io';

import 'package:sqlite_plus_orm_example/reading_log.dart';

Future<void> main() async {
  final log = await runReadingLog();
  stdout.writeln('${log.title} on ${log.shelf}, revision ${log.revision}; '
      '${log.otherTitle} stays at revision ${log.otherRevision}; '
      '${log.keptCount} match; idle save ${log.idleSave}');
}
