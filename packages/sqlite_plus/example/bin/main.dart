import 'dart:io';

import 'package:sqlite_plus_example/library_tour.dart';

Future<void> main() async {
  final tour = await runLibraryTour();
  stdout.writeln('${tour.title} (${tour.pages} pages) | ${tour.highlighted} '
      '| ${tour.arabicTitle} x${tour.arabicMatches} '
      '| place ${tour.placeId} | cards ${tour.keptCards} '
      '| version ${tour.userVersion} '
      '| reopen ${tour.reopenedTitle} v${tour.reopenedVersion} '
      '| ${tour.imageBytes} bytes');
}
